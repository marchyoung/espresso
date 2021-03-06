class EBuilder
  include EUtils
  include EConstants

  def self.call env
    new(:automount).call(env)
  end

  attr_reader :controllers, :mounted_controllers

  # creates new Espresso app.
  # 
  # @param automount  if set to any positive value(except Class, Module or Regexp),
  #                   all found controllers will be mounted,
  #                   if set to a Class, Module or Regexp,
  #                   only controllers under given namespace will be mounted.
  # @param [Proc] proc if block given, it will be executed inside newly created app
  #
  def initialize automount = false, &proc
    @controllers, @subcontrollers = {}, []
    @routes, @hosts, @controllers_hosts = {}, {}, {}
    @automount = automount
    proc && self.instance_exec(&proc)
    use ExtendedRack
    compiler_pool(Hash.new)
  end

  # mount given/discovered controllers into current app.
  # any number of arguments accepted.
  # String arguments are treated as roots/canonicals.
  # any other arguments are used to discover controllers.
  # controllers can be passed directly
  # or as a Module that contain controllers
  # or as a Regexp matching controller's name.
  # 
  # proc given here will be executed inside given/discovered controllers
  def mount *args, &setup
    root, controllers, applications = nil, [], []
    opts = args.last.is_a?(Hash) ? args.pop : {}
    args.flatten.each do |a|
      if a.is_a?(String)
        root = rootify_url(a)
      elsif is_app?(a)
        controllers << a
      elsif a.respond_to?(:call)
        applications << a
      else
        controllers.concat extract_controllers(a)
      end
    end
    controllers.each do |c|
      @controllers[c] = [root, opts, setup]
      c.subcontrollers.each do |sc|
        mount(sc, root.to_s + c.base_url, opts)
        @subcontrollers << sc
      end
    end
    
    mount_applications applications, root, opts

    self
  end

  # auto-mount auto-discovered controllers.
  # call this only after all controllers defined and app ready to start!
  # leaving it in public zone for better control over mounting.
  def automount!
    controllers = [Class, Module, Regexp].include?(@automount.class) ?
      extract_controllers(@automount) :
      discover_controllers
    mount controllers.select {|c| c.accept_automount?}
  end

  # proc given here will be executed inside all controllers.
  # used to setup multiple controllers at once.
  def global_setup &proc
    @global_setup = proc
    self
  end
  alias setup_controllers global_setup
  alias controllers_setup global_setup
  alias setup             global_setup

  # displays URLs the app will respond to,
  # with controller and action that serving each URL.
  def url_map opts = {}
    mount_controllers!
    map = sorted_routes.inject({}) do |m,r|
      @routes[r].each_pair {|rm,rs| (m[r] ||= {})[rm] = rs.dup}; m
    end

    def map.to_s
      out = ''
      self.each_pair do |route, request_methods|
        next if route.source.size == 0
        out << "%s\n" % route.source
        request_methods.each_pair do |rm,rs|
          out << "  %s%s" % [rm, ' ' * (10 - rm.to_s.size)]
          out << "%s\n" % (rs[:app] || [rs[:controller], rs[:action]]*'#')
        end
        out << "\n"
      end
      out
    end
    map
  end
  alias urlmap url_map

  def environment
    ENV[ENV__RACK_ENV] || :development
  end

  # by default, Espresso will use WEBrick server.
  # pass :server option and any option accepted by selected(or default) server:
  #
  # @example use Thin server on its default port
  #   app.run :server => :Thin
  # @example use EventedMongrel server with custom options
  #   app.run :server => :EventedMongrel, :port => 9090, :num_processors => 1000
  #
  # @param [Hash] opts
  # @option opts [Symbol]  :server (:WEBrick) web server
  # @option opts [Integer] :port   (5252)
  # @option opts [String]  :host   (0.0.0.0)
  #
  def run opts = {}
    boot!

    handler = opts.delete(:server)
    (handler && Rack::Handler.const_defined?(handler)) || (handler = HTTP__DEFAULT_SERVER)

    port = opts.delete(:port)
    opts[:Port] ||= port || HTTP__DEFAULT_PORT

    host = opts.delete(:host) || opts.delete(:bind)
    opts[:Host] = host if host

    $stderr.puts "\n--- Starting Espresso for %s on %s port backed by %s server ---\n\n" % [
      environment, opts[:Port], handler
    ]
    Rack::Handler.const_get(handler).run app, opts do |server|
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          $stderr.puts "\n--- Stopping Espresso... ---\n\n"
          server.respond_to?(:stop!) ? server.stop! : server.stop
        end
      end
      server.threaded = opts[:threaded] if server.respond_to? :threaded=
      yield server if block_given?
    end
  end

  def call env
    app.call env
  end

  def app
    @app ||= begin
      on_boot!
      mount_controllers!
      @sorted_routes = sorted_routes.freeze
      @routes.freeze
      middleware.reverse.inject(lambda {|env| call!(env)}) {|a,e| e[a]}
    end
  end

  def to_app
    app
    self
  end
  alias to_app! to_app
  alias boot!   to_app

  private
  def call! env
    path = env[ENV__PATH_INFO]
    script_name = env[ENV__SCRIPT_NAME]
    @sorted_routes.each do |route|
      if matches = route.match(path)

        if route_setup = @routes[route][env[ENV__REQUEST_METHOD]] || @routes[route][:*]

          if route_setup[:rewriter]
            break unless valid_host?(@hosts.merge(@controllers_hosts), env)
            app = ERewriter.new(*matches.captures, &route_setup[:rewriter])
            return app.call(env)
          elsif route_setup[:app]
            break unless valid_host?(@hosts.merge(@controllers_hosts), env)
            env[ENV__PATH_INFO] = normalize_path(matches[1].to_s)
            return route_setup[:app].call(env)
          else
            break unless valid_host?(@hosts.merge(route_setup[:controller].hosts), env)

            env[ENV__SCRIPT_NAME] = route_setup[:path].freeze
            env[ENV__PATH_INFO]   = normalize_path(matches[1].to_s)

            if format_regexp = route_setup[:format_regexp]
              env[ENV__ESPRESSO_PATH_INFO], env[ENV__ESPRESSO_FORMAT] = \
                env[ENV__PATH_INFO].split(format_regexp)
            end

            controller_instance = route_setup[:controller].new
            controller_instance.action_setup = route_setup
            app = Rack::Builder.new
            app.run controller_instance
            route_setup[:controller].middleware.each {|w,a,p| app.use w, *a, &p}
            return app.call(env)
          end
        else
          return [
            STATUS__NOT_IMPLEMENTED,
            {"Content-Type" => "text/plain"},
            ["Resource found but it can be accessed only through %s" % @routes[route].keys.join(", ")]
          ]
        end
      end
    end
    [
      STATUS__NOT_FOUND,
      {'Content-Type' => "text/plain", "X-Cascade" => "pass"},
      ['Not Found: %s' % env[ENV__PATH_INFO]]
    ]
  ensure
    env[ENV__PATH_INFO] = path
    env[ENV__SCRIPT_NAME] = script_name
  end

  def sorted_routes
    @routes.keys.sort {|a,b| b.source.size <=> a.source.size}
  end

  def valid_host? accepted_hosts, env
    http_host, server_name, server_port =
      env.values_at(ENV__HTTP_HOST, ENV__SERVER_NAME, ENV__SERVER_PORT)
    accepted_hosts[http_host] ||
      accepted_hosts[server_name] ||
      http_host == server_name ||
      http_host == server_name+':'+server_port
  end

  def normalize_path path
    (path_ok?(path) ? path : '/' << path).freeze
  end

  # checking whether path is empty or starts with a slash
  def path_ok? path
    # comparing fixnums are much faster than comparing strings
    path.hash == (@empty_string_hash ||= '' .hash) || # faster than path.empty?
      path[0].hash == (@slash_hash   ||= '/'.hash)    # faster than path =~ /^\//
  end

  def mount_controllers!
    automount! if @automount
    @mounted_controllers = []
    @controllers.each_pair {|c,(root,opts,setup)| mount_controller(c, root, opts, &setup)}
  end

  def mount_controller controller, root = nil, opts = {}, &setup
    return if @mounted_controllers.include?(controller)
    root.is_a?(Hash) && (opts = root) && (root = nil)

    if root || base_url.size > 0
      controller.remap!(base_url + root.to_s, opts)
    end

    unless @subcontrollers.include?(controller)
      @global_setup && controller.global_setup!(&@global_setup)
      setup && controller.external_setup!(&setup)
    end

    controller.mount! self

    @routes.update controller.routes
    @controllers_hosts.update controller.hosts
    controller.rewrite_rules.each {|(rule,proc)| rewrite_rule(rule, &proc)}

    @mounted_controllers << controller
  end

  def discover_controllers namespace = nil
    controllers = ObjectSpace.each_object(Class).
      select { |c| is_app?(c) }.reject { |c| [E].include? c }
    namespace.is_a?(Regexp) ?
      controllers.select { |c| c.name =~ namespace } :
      controllers
  end
  alias discovered_controllers discover_controllers

  def extract_controllers namespace
    if [Class, Module].include?(namespace.class)
      return discover_controllers.select {|c| c.name =~ /\A#{namespace}/}
    end
    discover_controllers namespace
  end

  def mount_applications applications, root = nil, opts = {}
    applications = [applications] unless applications.is_a?(Array)
    applications.compact!
    return if applications.empty?
    root.is_a?(Hash) && (opts = root) && (root = nil)

    request_methods = (opts[:on] || opts[:request_method] || opts[:request_methods])
    request_methods = [request_methods] unless request_methods.is_a?(Array)
    request_methods.compact!
    request_methods.map! {|m| m.to_s.upcase}.reject! do |m|
      HTTP__REQUEST_METHODS.none? {|lm| lm == m}
    end
    request_methods = HTTP__REQUEST_METHODS if request_methods.empty?

    route = route_to_regexp(rootify_url(root || '/'))
    applications.each do |a|
      @routes[route] = request_methods.inject({}) {|map,m| map.merge(m => {app: a})}
    end
  end
  alias mount_application mount_applications

  # execute blocks defined via `on_boot`
  def on_boot!
    (@on_boot || []).each {|b| b.call}
  end

  # Some Rack handlers (Thin, Rainbows!) implement an extended body object protocol, however,
  # some middleware (namely Rack::Lint) will break it by not mirroring the methods in question.
  # This middleware will detect an extended body object and will make sure it reaches the
  # handler directly. We do this here, so our middleware and middleware set up by the app will
  # still be able to run.
  unless defined?(EBuilder::ExtendedRack)
    class ExtendedRack < Struct.new(:app) # kindly borrowed from Sinatra
      def call(env)
        result, callback = app.call(env), env['async.callback']
        return result unless callback and async?(*result)
        after_response { callback.call result }
        setup_close(env, *result)
        throw :async
      end

      private
      def setup_close(env, status, header, body)
        return unless body.respond_to? :close and env.include? 'async.close'
        env['async.close'].callback { body.close }
        env['async.close'].errback { body.close }
      end

      def after_response(&block)
        raise NotImplementedError, "only supports EventMachine at the moment" unless defined? EventMachine
        EventMachine.next_tick(&block)
      end

      def async?(status, headers, body)
        return true if status == -1
        body.respond_to? :callback and body.respond_to? :errback
      end
    end
  end
end
