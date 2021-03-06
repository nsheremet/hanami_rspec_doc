module Had
  class Collector
    # Contains spec values read from rspec example, request and response
    attr_accessor :records

    # Param importances
    PARAM_IMPORTANCES = %w[required optional conditional deprecated]

    # Param types
    # NOTE: make sure sub-strings go at the end
    PARAM_TYPES = ['Boolean', 'Text', 'Float', 'DateTime', 'Date', 'File', 'UUID', 'Hash',
                   'Array of Integer', 'Array of String', 'Array', 'Integer', 'String',
                   'Email']

    # Exclude replacement in symbolized path
    EXCLUDE_PARAMS = %w[limit offset format description controller action]

    # response headers contain many unnecessary information,
    # everything from this list will be stripped
    EXCLUDE_RESPONSE_HEADER_PATTERNS = %w[
      Cache-Control
      ETag
      X-Content-Type-Options
      X-Frame-Options
      X-Request-Id
      X-Runtime
      X-UA-Compatible
      X-XSS-Protection
      Vary
      Last-Modified
    ]

    # request headers contain many unnecessary information,
    # everything that match items from this list will be stripped
    EXCLUDE_REQUEST_HEADER_PATTERNS = %w[
      action_controller.
      action_dispatch
      CONTENT_LENGTH
      HTTP_COOKIE
      HTTP_HOST
      HTTP_ORIGIN
      HTTP_USER_AGENT
      HTTPS
      ORIGINAL_FULLPATH
      ORIGINAL_SCRIPT_NAME
      PATH_INFO
      QUERY_STRING
      rack.
      raven.requested_at
      RAW_POST_DATA
      REMOTE_ADDR
      REQUEST_METHOD
      REQUEST_URI
      ROUTES_
      SCRIPT_NAME
      SERVER_NAME
      SERVER_PORT
      sinatra.commonlogger
      sinatra.route
      HTTP_X_API
      warden
      devise.mapping
    ]

    def initialize
      self.records = []
    end

    # collects spec data for further processing
    def collect(spec, example, request, response)
      # TODO: remove boilerplate code
      return if request.nil? || response.nil? || !defined?(request.params.env)

      description = query_parameters = backend_parameters = 'not available'
      params = []

      if request.params.env && (request_params = request.params)
        action = request.class.name.split('::').last
        controller = request.class.name.split('::')[-2]
        description = get_action_description(controller, action)
        # description = request.class.to_s
        routes_params = get_routes_params(controller, action)
        params = get_action_params(controller, action)
        query_parameters = request_params.to_h.reject { |p| %w[controller action format].include? p }
        backend_parameters = request_params.to_h.reject { |p| !%w[controller action format].include? p }
      end

      ex_gr = spec.class.example.metadata[:example_group]
      section = ex_gr[:description]
      while !ex_gr.nil? do
        section = ex_gr[:description]
        ex_gr = ex_gr[:parent_example_group]
      end

      self.records << {
        filename: prepare_filename_for(spec.class.metadata),
        group: spec.class.metadata[:had_section] || section,
        title: example_title(spec, example),
        description: description,
        params: params,
        request: {
          host: Had.host,
          url: Had.host + routes_params['path'],
          path: routes_params['path'],
          symbolized_path: Had.host + routes_params['path'],
          method: routes_params['method'],
          query_parameters: query_parameters,
          backend_parameters: backend_parameters,
          body: request.instance_variable_get("@_body"),
          content_length: query_parameters.to_s.size,
          content_type: request.content_type,
          headers: read_request_headers(request),
          accept: (request.accept rescue nil)
        },
        response: {
          code: response.first,
          body: response.last.last,
          headers: read_response_headers(response),
          format: format(response)
        }
      }

      # cleanup query params
      begin
        body_hash = JSON.parse(self.records.last[:request][:body])
        query_hash = self.records.last[:request][:query_parameters]
        diff = Hash[*((query_hash.size > body_hash.size) ? query_hash.to_a - body_hash.to_a : body_hash.to_a - query_hash.to_a).flatten]
        self.records.last[:request][:query_parameters] = diff
      rescue
      end
    end

    def prepare_filename_for(metadata)
      description = metadata[:description]
      example_group = if metadata.key?(:example_group)
                        metadata[:example_group]
                      else
                        metadata[:parent_example_group]
                      end

      if example_group
        [prepare_filename_for(example_group), description].join('/')
      else
        description
      end.downcase.gsub(/[\W]+/, '_').gsub('__', '_').gsub(/^_|_$/, '')
    end

    # sorts records alphabetically
    def sort
      self.records.sort! do |x,y|
        comp = x[:request][:symbolized_path] <=> y[:request][:symbolized_path]
        comp.zero? ? (x[:title] <=> y[:title]) : comp
      end
    end

    private

    def example_title(spec, example)
      t = prepare_description(example.metadata, :had_title) ||
          spec.class.example.full_description
      t.strip
    end

    def prepare_description(payload, key)
      payload[key] &&
        ->(x) { (x.is_a?(TrueClass) || x == '') ? payload[:description] : x }.call(payload[key])
    end

    # read and cleanup response headers
    # returns Hash
    def read_response_headers(response)
      raw_headers = response[1]
      headers = {}
      EXCLUDE_RESPONSE_HEADER_PATTERNS.each do |pattern|
        raw_headers = raw_headers.reject { |h| h if h.start_with? pattern }
      end
      raw_headers.each do |key, val|
        headers.merge!(cleanup_header(key) => val)
      end
      headers
    end

    def format(response)
      case response[1]['Content-Type']
      when %r{text/html}
        :html
      when %r{application/json}
        :json
      else
        :json
      end
    end

    # read and cleanup request headers
    # returns Hash
    def read_request_headers(request)
      headers = {}
      request.params.env.keys.each do |key|
        if EXCLUDE_REQUEST_HEADER_PATTERNS.all? { |p| !key.to_s.start_with? p }
          headers.merge!(cleanup_header(key) => request.params.env[key])
        end
      end
      headers
    end

    # replace each first occurrence of param's value in the request path
    #
    # Example:
    #   request path = /api/users/123
    #   id = 123
    #   symbolized path => /api/users/:id
    #
    def get_symbolized_path(request)
      request_path = request.env['REQUEST_URI'] || request.path
      request_params =
        request.env['action_dispatch.request.parameters'] ||
        request.env['rack.request.form_hash'] ||
        request.env['rack.request.query_hash']

      if request_params
        request_params
          .except(*EXCLUDE_PARAMS)
          .select { |_, value| value.is_a?(String) }
          .each { |key, value| request_path.sub!("/#{value}", "/:#{key}") if value.to_s != '' }
      end

      request_path
    end

    # returns action comments taken from controller file
    # example TODO
    def get_action_comments(controller, action)
      lines = File.readlines(File.join(Had.root, 'app', 'controllers', "#{controller}", "#{action}.rb"))

      action_line = nil
      lines.each_with_index do |line, index|
        if line.match(/\s*def call/)
          action_line = index
          break
        end
      end

      if action_line
        comment_lines = []
        request_additionals = {}
        was_comment = true
        while action_line > 0 && was_comment
          action_line -= 1

          if lines[action_line].match(/\s*#/)
            comment_lines << lines[action_line].strip
          else
            was_comment = false
          end
        end

        comment_lines.reverse
      else
        ['not found']
      end
    rescue Errno::ENOENT
      ['not found']
    end

    # returns routes information
    # example TODO
    def get_routes_params(controller, action)
      lines = File.readlines(File.join(Had.root, 'config', 'routes.rb'))
      data = {}

      lines.each do |line|
        if line.match(/\s*#{controller.underscore}##{action.underscore}/)
          array = line.split(' ')
          data['method'] = array[0].upcase
          data['path'] = array[1].split("'")[1]
        end
      end

      data
    end

    # returns description action comments
    # example TODO
    def get_action_description(controller, action)
      comment_lines = get_action_comments(controller, action)
      info = {}
      description = []
      comment_lines.each_with_index do |line, index|
        if line.match(/\s*#\s*@description/) # @description blah blah
          description << line.gsub(/\A\s*#\s*@description/, '').strip
          comment_lines[(index + 1)..-1].each do |multiline|
            if !multiline.match(/\s*#\s*@param/)
              description << "\n"
              description << multiline.gsub(/\A\s*#\s*/, '').strip
            else
              break
            end
          end
        end
      end

      description.join(' ')
    end

    # returns params action comments
    # example TODO
    def get_action_params(controller, action)
      # This way using for getting params from parsing dry-validation schemes
      params_lines = get_params_lines(controller, action)
      comments = get_params_comments(params_lines)

      return comments unless comments.empty?

      # This way using for getting params form comments
      comment_lines = get_action_comments(controller, action)
      comments_raw = []
      has_param = false

      comment_lines.each do |line|
        if line.match(/\s*#\s*@param/) # @param id required Integer blah blah
          has_param = true
          comments_raw << ''
        end
        if has_param
          line = line.gsub(/\A\s*#\s*@param/, '')
          line = line.gsub(/\A\s*#\s*/, '').strip

          comments_raw.last << "\n" unless comments_raw.last.empty?
          comments_raw.last << line
        end
      end

      comments = []
      comments_raw.each do |comment|
        match_data = comment.match(/(?<name>[a-z0-9A-Z_\[\]]+)?\s*(?<required>#{PARAM_IMPORTANCES.join('|')})?\s*(?<type>#{PARAM_TYPES.join('|')})?\s*(?<description>.*)/m)

        if match_data
          comments << {
            name: match_data[:name],
            required: match_data[:required],
            type: match_data[:type],
            description: match_data[:description]
          }
        else
          comments << { description: comment }
        end
      end

      comments
    end

    # return params comments parsed from params_lines
    # example TODO
    def get_params_comments(params_lines)
      parent_params = nil
      comments = []

      params_lines.each do |line|
        if line.match(/\s*(required|optional)\(:\w*\)\.\w*/) &&
            !line.match(/\s*(required|optional)\(:\w*\)\.\w*\s(do)/)

          name = line.split('(')[1].split(')')[0].tr(':', '')
          required = line.match(/\s(required|optional)/).to_s.strip
          description = line.match(/\s*#/) ? line.split('#').last.strip : '--'

          type = if line.match(/\s*(required|optional)\(:\w*\)\.\w*\(:\w*\?\)/)
            line.split('(')[2].split(')')[0].tr(':?', '')
          else
            'Any'
          end

          name = "#{parent_params}[#{name}]" unless parent_params.nil?

          comments << {
            name: name,
            required: required,
            type: type,
            description: description
          }
        end

        parent_params = false if line.match(/\s(end)/)

        if line.match(/\s*(required|optional)\(:\w*\)\.\w*\s(do)/)
          str = line.split('(')[1].split(')')[0].tr(':', '')

          if parent_params.nil?
            parent_params = str
          else
            parent_params = "#{parent_params}[#{str}]"
          end
        end
      end

      comments
    rescue Exception
      []
    end

    # returns dry-validations params lines
    # example TODO
    def get_params_lines(controller, action)
      lines = File.readlines(File.join(Had.root, 'app', 'controllers', "#{controller.underscore}", "#{action.underscore}.rb"))
      params_lines = []
      params_begins = false
      ends_left = 0

      lines.each_with_index do |line, index|
        if line.match(/\s*params do/)
          params_lines << line
          params_begins = true
          ends_left += 1

          next
        end

        if params_begins
          params_lines << line

          if line.match(/\s*do/)
            ends_left += 1
          elsif line.match(/\s*end/)
            ends_left -= 1
          end
        end

        params_begins = false if ends_left <= 0
      end

      params_lines
    rescue Exception
      {}
    end

    def cleanup_header(key)
      key.to_s.sub(/^HTTP_/, '').underscore.split('_').map(&:capitalize).join('-')
    end
  end
end
