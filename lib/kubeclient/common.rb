require 'json'
require 'http'
require 'rest-client'
require 'circuitbox'
require 'activesupport'

module Kubeclient
  # Common methods
  # this is mixed in by other gems
  module ClientMixin
    ENTITY_METHODS = %w[get watch delete create update patch].freeze

    DEFAULT_SSL_OPTIONS = {
      client_cert: nil,
      client_key:  nil,
      ca_file:     nil,
      cert_store:  nil,
      verify_ssl:  OpenSSL::SSL::VERIFY_PEER
    }.freeze

    DEFAULT_AUTH_OPTIONS = {
      username:          nil,
      password:          nil,
      bearer_token:      nil,
      bearer_token_file: nil
    }.freeze

    DEFAULT_SOCKET_OPTIONS = {
      socket_class:     nil,
      ssl_socket_class: nil
    }.freeze

    DEFAULT_TIMEOUTS = {
      # TODO(cmkirkla): move this hardcoded configuration to fluentd-plugin-kubernetes_metadata_filter
      open: 15, # seconds
      read: 15  # seconds
    }.freeze

    DEFAULT_HTTP_PROXY_URI = nil

    SEARCH_ARGUMENTS = {
      'labelSelector' => :label_selector,
      'fieldSelector' => :field_selector
    }.freeze

    WATCH_ARGUMENTS = { 'resourceVersion' => :resource_version }.merge!(SEARCH_ARGUMENTS).freeze

    attr_reader :api_endpoint
    attr_reader :ssl_options
    attr_reader :auth_options
    attr_reader :http_proxy_uri
    attr_reader :headers
    attr_reader :discovered

    def initialize_client(
      uri,
      path,
      version,
      ssl_options: DEFAULT_SSL_OPTIONS,
      auth_options: DEFAULT_AUTH_OPTIONS,
      socket_options: DEFAULT_SOCKET_OPTIONS,
      timeouts: DEFAULT_TIMEOUTS,
      http_proxy_uri: DEFAULT_HTTP_PROXY_URI,
      as: :ros
    )
      validate_auth_options(auth_options)
      handle_uri(uri, path)

      @entities = {}
      @discovered = false
      @api_version = version
      @headers = {}
      @ssl_options = ssl_options
      @auth_options = auth_options
      @socket_options = socket_options
      # Allow passing partial timeouts hash, without unspecified
      # @timeouts[:foo] == nil resulting in infinite timeout.
      @timeouts = DEFAULT_TIMEOUTS.merge(timeouts)
      @http_proxy_uri = http_proxy_uri ? http_proxy_uri.to_s : nil
      @as = as

      if auth_options[:bearer_token]
        bearer_token(@auth_options[:bearer_token])
      elsif auth_options[:bearer_token_file]
        validate_bearer_token_file
        bearer_token(File.read(@auth_options[:bearer_token_file]))
      end

    end

    def method_missing(method_sym, *args, &block)
      if discovery_needed?(method_sym)
        discover
        send(method_sym, *args, &block)
      else
        super
      end
    end

    def respond_to_missing?(method_sym, include_private = false)
      if discovery_needed?(method_sym)
        discover
        respond_to?(method_sym, include_private)
      else
        super
      end
    end

    def discovery_needed?(method_sym)
      !@discovered && ENTITY_METHODS.any? { |x| method_sym.to_s.start_with?(x) }
    end

    def handle_exception
      yield
    rescue RestClient::Exception => e
      json_error_msg = begin
        JSON.parse(e.response || '') || {}
      rescue JSON::ParserError
        {}
      end
      err_message = json_error_msg['message'] || e.message
      error_klass = e.http_code == 404 ? ResourceNotFoundError : HttpError
      raise error_klass.new(e.http_code, err_message, e.response)
    end

    def discover
      load_entities
      define_entity_methods
      @discovered = true
    end

    def self.parse_definition(kind, name)
      # "name": "componentstatuses", networkpolicies, endpoints
      # "kind": "ComponentStatus" NetworkPolicy, Endpoints
      # maintain pre group api compatibility for endpoints and securitycontextconstraints.
      # See: https://github.com/kubernetes/kubernetes/issues/8115
      kind = kind[0..-2] if %w[Endpoints SecurityContextConstraints].include?(kind)

      prefix = kind[0..kind.rindex(/[A-Z]/)] # NetworkP
      m = name.match(/^#{prefix.downcase}(.*)$/)
      m && OpenStruct.new(
        entity_type:   kind, # ComponentStatus
        resource_name: name, # componentstatuses
        method_names:  [
          ClientMixin.underscore_entity(kind),         # component_status
          ClientMixin.underscore_entity(prefix) + m[1] # component_statuses
        ]
      )
    end

    def handle_uri(uri, path)
      raise ArgumentError, 'Missing uri' unless uri
      @api_endpoint = (uri.is_a?(URI) ? uri : URI.parse(uri))
      @api_endpoint.path = path if @api_endpoint.path.empty?
      @api_endpoint.path = @api_endpoint.path.chop if @api_endpoint.path.end_with?('/')
      components = @api_endpoint.path.to_s.split('/') # ["", "api"] or ["", "apis", batch]
      @api_group = components.length > 2 ? components[2] + '/' : ''
    end

    def build_namespace_prefix(namespace)
      namespace.to_s.empty? ? '' : "namespaces/#{namespace}/"
    end

    def define_entity_methods
      @entities.values.each do |entity|
        # get all entities of a type e.g. get_nodes, get_pods, etc.
        define_singleton_method("get_#{entity.method_names[1]}") do |options = {}|
          get_entities(entity.entity_type, entity.resource_name, options)
        end

        # watch all entities of a type e.g. watch_nodes, watch_pods, etc.
        define_singleton_method("watch_#{entity.method_names[1]}") do |options = {}|
          # This method used to take resource_version as a param, so
          # this conversion is to keep backwards compatibility
          options = { resource_version: options } unless options.is_a?(Hash)

          watch_entities(entity.resource_name, options)
        end

        # get a single entity of a specific type by name
        define_singleton_method("get_#{entity.method_names[0]}") \
        do |name, namespace = nil, opts = {}|
          get_entity(entity.resource_name, name, namespace, opts)
        end

        define_singleton_method("delete_#{entity.method_names[0]}") \
        do |name, namespace = nil, opts = {}|
          delete_entity(entity.resource_name, name, namespace, opts)
        end

        define_singleton_method("create_#{entity.method_names[0]}") do |entity_config|
          create_entity(entity.entity_type, entity.resource_name, entity_config)
        end

        define_singleton_method("update_#{entity.method_names[0]}") do |entity_config|
          update_entity(entity.resource_name, entity_config)
        end

        define_singleton_method("patch_#{entity.method_names[0]}") do |name, patch, namespace = nil|
          patch_entity(entity.resource_name, name, patch, namespace)
        end
      end
    end

    def self.underscore_entity(entity_name)
      entity_name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    end

    def create_rest_client(path = nil)
      path ||= @api_endpoint.path
      options = {
        ssl_ca_file: @ssl_options[:ca_file],
        ssl_cert_store: @ssl_options[:cert_store],
        verify_ssl: @ssl_options[:verify_ssl],
        ssl_client_cert: @ssl_options[:client_cert],
        ssl_client_key: @ssl_options[:client_key],
        proxy: @http_proxy_uri,
        user: @auth_options[:username],
        password: @auth_options[:password],
        open_timeout: @timeouts[:open],
        read_timeout: @timeouts[:read]
      }
      Kubeclient::Common::RestResource.new(@api_endpoint.merge(path).to_s, options)
    end

    def rest_client
      @rest_client ||= begin
        create_rest_client("#{@api_endpoint.path}/#{@api_version}")
      end
    end

    # Accepts the following options:
    #   :namespace (string) - the namespace of the entity.
    #   :name (string) - the name of the entity to watch.
    #   :label_selector (string) - a selector to restrict the list of returned objects by labels.
    #   :field_selector (string) - a selector to restrict the list of returned objects by fields.
    #   :resource_version (string) - shows changes that occur after passed version of a resource.
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    def watch_entities(resource_name, options = {})
      ns = build_namespace_prefix(options[:namespace])

      path = "watch/#{ns}#{resource_name}"
      path += "/#{options[:name]}" if options[:name]
      uri = @api_endpoint.merge("#{@api_endpoint.path}/#{@api_version}/#{path}")

      params = {}
      WATCH_ARGUMENTS.each { |k, v| params[k] = options[v] if options[v] }
      uri.query = URI.encode_www_form(params) if params.any?

      Kubeclient::Common::WatchStream.new(
        uri,
        http_options(uri),
        formatter: ->(value) { format_response(options[:as] || @as, value) }
      )
    end

    # Accepts the following options:
    #   :namespace (string) - the namespace of the entity.
    #   :label_selector (string) - a selector to restrict the list of returned objects by labels.
    #   :field_selector (string) - a selector to restrict the list of returned objects by fields.
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    def get_entities(entity_type, resource_name, options = {})
      params = {}
      SEARCH_ARGUMENTS.each { |k, v| params[k] = options[v] if options[v] }

      ns_prefix = build_namespace_prefix(options[:namespace])
      response = handle_exception do
        rest_client[ns_prefix + resource_name]
          .get({ 'params' => params }.merge(@headers))
      end
      format_response(options[:as] || @as, response.body, entity_type)
    end

    # Accepts the following options:
    #   :as (:raw|:ros) - defaults to :ros
    #     :raw - return the raw response body as a string
    #     :ros - return a collection of RecursiveOpenStruct objects
    def get_entity(resource_name, name, namespace = nil, options = {})
      ns_prefix = build_namespace_prefix(namespace)
      response = handle_exception do
        rest_client[ns_prefix + resource_name + "/#{name}"]
          .get(@headers)
      end
      format_response(options[:as] || @as, response.body)
    end

    # delete_options are passed as a JSON payload in the delete request
    def delete_entity(resource_name, name, namespace = nil, delete_options: {})
      delete_options_hash = delete_options.to_hash
      ns_prefix = build_namespace_prefix(namespace)
      payload = delete_options_hash.to_json unless delete_options_hash.empty?
      response = handle_exception do
        rs = rest_client[ns_prefix + resource_name + "/#{name}"]
        RestClient::Request.execute(
          rs.options.merge(
            method: :delete,
            url: rs.url,
            headers: { 'Content-Type' => 'application/json' }.merge(@headers),
            payload: payload
          )
        )
      end
      format_response(@as, response.body)
    end

    def create_entity(entity_type, resource_name, entity_config)
      # Duplicate the entity_config to a hash so that when we assign
      # kind and apiVersion, this does not mutate original entity_config obj.
      hash = entity_config.to_hash

      ns_prefix = build_namespace_prefix(hash[:metadata][:namespace])

      # TODO: temporary solution to add "kind" and apiVersion to request
      # until this issue is solved
      # https://github.com/GoogleCloudPlatform/kubernetes/issues/6439
      # TODO: #2 solution for
      # https://github.com/kubernetes/kubernetes/issues/8115
      hash[:kind] = (entity_type.eql?('Endpoint') ? 'Endpoints' : entity_type)
      hash[:apiVersion] = @api_group + @api_version
      response = handle_exception do
        rest_client[ns_prefix + resource_name]
          .post(hash.to_json, { 'Content-Type' => 'application/json' }.merge(@headers))
      end
      format_response(@as, response.body)
    end

    def update_entity(resource_name, entity_config)
      name      = entity_config[:metadata][:name]
      ns_prefix = build_namespace_prefix(entity_config[:metadata][:namespace])
      response = handle_exception do
        rest_client[ns_prefix + resource_name + "/#{name}"]
          .put(entity_config.to_h.to_json, { 'Content-Type' => 'application/json' }.merge(@headers))
      end
      format_response(@as, response.body)
    end

    def patch_entity(resource_name, name, patch, namespace = nil)
      ns_prefix = build_namespace_prefix(namespace)
      response = handle_exception do
        rest_client[ns_prefix + resource_name + "/#{name}"]
          .patch(
            patch.to_json,
            { 'Content-Type' => 'application/strategic-merge-patch+json' }.merge(@headers)
          )
      end
      format_response(@as, response.body)
    end

    def all_entities(options = {})
      discover unless @discovered
      @entities.values.each_with_object({}) do |entity, result_hash|
        # method call for get each entities
        # build hash of entity name to array of the entities
        method_name = "get_#{entity.method_names[1]}"
        begin
          result_hash[entity.method_names[0]] = send(method_name, options)
        rescue Kubeclient::HttpError
          next # do not fail due to resources not supporting get
        end
      end
    end

    def get_pod_log(pod_name, namespace,
                    container: nil, previous: false,
                    timestamps: false, since_time: nil, tail_lines: nil)
      params = {}
      params[:previous] = true if previous
      params[:container] = container if container
      params[:timestamps] = timestamps if timestamps
      params[:sinceTime] = format_datetime(since_time) if since_time
      params[:tailLines] = tail_lines if tail_lines

      ns = build_namespace_prefix(namespace)
      handle_exception do
        rest_client[ns + "pods/#{pod_name}/log"]
          .get({ 'params' => params }.merge(@headers))
      end
    end

    def watch_pod_log(pod_name, namespace, container: nil)
      # Adding the "follow=true" query param tells the Kubernetes API to keep
      # the connection open and stream updates to the log.
      params = { follow: true }
      params[:container] = container if container

      ns = build_namespace_prefix(namespace)

      uri = @api_endpoint.dup
      uri.path += "/#{@api_version}/#{ns}pods/#{pod_name}/log"
      uri.query = URI.encode_www_form(params)

      Kubeclient::Common::WatchStream.new(uri, http_options(uri), formatter: ->(value) { value })
    end

    def proxy_url(kind, name, port, namespace = '')
      discover unless @discovered
      entity_name_plural =
        if %w[services pods nodes].include?(kind.to_s)
          kind.to_s
        else
          @entities[kind.to_s].resource_name
        end
      ns_prefix = build_namespace_prefix(namespace)
      rest_client["#{ns_prefix}#{entity_name_plural}/#{name}:#{port}/proxy"].url
    end

    def process_template(template)
      ns_prefix = build_namespace_prefix(template[:metadata][:namespace])
      response = handle_exception do
        rest_client[ns_prefix + 'processedtemplates']
          .post(template.to_h.to_json, { 'Content-Type' => 'application/json' }.merge(@headers))
      end
      JSON.parse(response)
    end

    def api_valid?
      result = api
      result.is_a?(Hash) && (result['versions'] || []).any? do |group|
        @api_group.empty? ? group.include?(@api_version) : group['version'] == @api_version
      end
    end

    def api
      response = handle_exception { create_rest_client.get(@headers) }
      JSON.parse(response)
    end

    private

    # Format ditetime according to RFC3339
    def format_datetime(value)
      case value
      when DateTime, Time
        value.strftime('%FT%T.%9N%:z')
      when String
        value
      else
        raise ArgumentError, "unsupported type '#{value.class}' of time value '#{value}'"
      end
    end

    def format_response(as, body, list_type = nil)
      case as
      when :raw
        body
      when :parsed
        JSON.parse(body)
      when :parsed_symbolized
        JSON.parse(body, symbolize_names: true)
      when :ros
        result = JSON.parse(body)

        if list_type
          resource_version =
            result.fetch('resourceVersion') do
              result.fetch('metadata', {}).fetch('resourceVersion', nil)
            end

          # result['items'] might be nil due to https://github.com/kubernetes/kubernetes/issues/13096
          collection = result['items'].to_a.map { |item| Kubeclient::Resource.new(item) }

          Kubeclient::Common::EntityList.new(list_type, resource_version, collection)
        else
          Kubeclient::Resource.new(result)
        end
      else
        raise ArgumentError, "Unsupported format #{as.inspect}"
      end
    end

    def load_entities
      @entities = {}
      fetch_entities['resources'].each do |resource|
        next if resource['name'].include?('/')
        resource['kind'] ||=
          Kubeclient::Common::MissingKindCompatibility.resource_kind(resource['name'])
        entity = ClientMixin.parse_definition(resource['kind'], resource['name'])
        @entities[entity.method_names[0]] = entity if entity
      end
    end

    def fetch_entities
      JSON.parse(handle_exception { rest_client.get(@headers) })
    end

    def bearer_token(bearer_token)
      @headers ||= {}
      @headers[:Authorization] = "Bearer #{bearer_token}"
    end

    def validate_auth_options(opts)
      # maintain backward compatibility:
      opts[:username] = opts[:user] if opts[:user]

      if %i[bearer_token bearer_token_file username].count { |key| opts[key] } > 1
        raise(
          ArgumentError,
          'Invalid auth options: specify only one of username/password,' \
          ' bearer_token or bearer_token_file'
        )
      elsif %i[username password].count { |key| opts[key] } == 1
        raise ArgumentError, 'Basic auth requires both username & password'
      end
    end

    def validate_bearer_token_file
      msg = "Token file #{@auth_options[:bearer_token_file]} does not exist"
      raise ArgumentError, msg unless File.file?(@auth_options[:bearer_token_file])

      msg = "Cannot read token file #{@auth_options[:bearer_token_file]}"
      raise ArgumentError, msg unless File.readable?(@auth_options[:bearer_token_file])
    end

    def http_options(uri)
      options = {
        basic_auth_user: @auth_options[:username],
        basic_auth_password: @auth_options[:password],
        headers: @headers,
        http_proxy_uri: @http_proxy_uri
      }

      if uri.scheme == 'https'
        options[:ssl] = {
          ca_file: @ssl_options[:ca_file],
          cert: @ssl_options[:client_cert],
          cert_store: @ssl_options[:cert_store],
          key: @ssl_options[:client_key],
          # ruby HTTP uses verify_mode instead of verify_ssl
          # http://ruby-doc.org/stdlib-1.9.3/libdoc/openssl/rdoc/OpenSSL/SSL/SSLContext.html
          verify_mode: @ssl_options[:verify_ssl]
        }
      end

      options.merge(@socket_options)
    end
  end

  #TODO(chriskirkland): add circuit breaker enabled implementation for RestClient::Request.execute()
  module Common
    # RestClient::Resource wrapped with a global circuit breaker
    class RestResource < RestClient::Resource
      def initialize(uri, options={}, backwards_compatibility=nil, &block)
        super

        @logger = Logger.new(STDOUT)
        @circuit = Circuitbox.circuit(:apiserver, {
          # exceptions circuitbox tracks for counting failures (required)
          exceptions:       [RestClient::Exception],
          # seconds the circuit stays open once it has passed the error threshold
          sleep_window:     180,
          # length of interval (in seconds) over which it calculates the error rate
          time_window:      120,
          # exceeding this rate (percentage) will open the circuit
          error_threshold:  50,
          # number of requests within `time_window` seconds before it calculates error rates
          volume_threshold: 4,
          # user file-based cache to support multi-processing and restart persistence
          cache: Moneta.new(:File, dir: '/mnt/ibm-kube-fluentd-persist/circuitbreaker'),
        })

        # setup notifications
        ActiveSupport::Notifications.subscribe('circuit_open') do |name, start, finish, id, payload|
          circuit_name = payload[:circuit]
          @logger.warn("circuit for #{circuit_name} opened")
        end
        ActiveSupport::Notifications.subscribe('circuit_close') do |name, start, finish, id, payload|
          circuit_name = payload[:circuit]
          @logger.warn("circuit for #{circuit_name} closed")
        end
      end

      def delete(additional_headers={}, &block)
        @circuit.run { super }
      end

      def get(additional_headers={}, &block)
        @circuit.run { super }
      end

      def head(additional_headers={}, &block)
        @circuit.run { super }
      end

      def patch(payload, additional_headers={}, &block)
        @circuit.run { super }
      end

      def post(payload, additional_headers={}, &block)
        @circuit.run { super }
      end

      def put(payload, additional_headers={}, &block)
        @circuit.run { super }
      end
    end
  end
end
