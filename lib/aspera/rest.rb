# frozen_string_literal: true

require 'aspera/rest_errors_aspera'
require 'aspera/rest_error_analyzer'
require 'aspera/log'
require 'aspera/assert'
require 'aspera/oauth'
require 'aspera/hash_ext'
require 'net/http'
require 'net/https'
require 'json'
require 'base64'
require 'cgi'

# Cancel method for HTTP
class Net::HTTP::Cancel < Net::HTTPRequest # rubocop:disable Style/ClassAndModuleChildren
  METHOD = 'CANCEL'
  REQUEST_HAS_BODY  = false
  RESPONSE_HAS_BODY = false
end

module Aspera
  # a simple class to make HTTP calls, equivalent to rest-client
  # rest call errors are raised as exception RestCallError
  # and error are analyzed in RestErrorAnalyzer
  class Rest
    # Global settings also valid for any subclass
    # @param user_agent [String] HTTP request header: 'User-Agent'
    # @param download_partial_suffix [String] suffix for partial download
    # @param session_cb [lambda] lambda called on new HTTP session. Takes the Net::HTTP as arg. Used to change parameters on creation.
    # @param progress_bar [Object] progress bar object
    @@global = { # rubocop:disable Style/ClassVars
      user_agent:              'RubyAsperaRest',
      download_partial_suffix: '.http_partial',
      session_cb:              nil,
      progress_bar:            nil
    }

    # flag for array parameters prefixed with []
    ARRAY_PARAMS = '[]'

    private_constant :ARRAY_PARAMS

    # error message when entity not found (TODO: use specific exception)
    ENTITY_NOT_FOUND = 'No such'

    # Content-Type that are JSON
    JSON_DECODE = ['application/json', 'application/vnd.api+json', 'application/x-javascript'].freeze

    class << self
      # @return [String] Basic auth token
      def basic_token(user, pass); return "Basic #{Base64.strict_encode64("#{user}:#{pass}")}"; end

      # Build a parameter list prefixed with "[]"
      # @param values [Array] list of values
      def array_params(values)
        return [ARRAY_PARAMS].concat(values)
      end

      def array_params?(values)
        return values.first.eql?(ARRAY_PARAMS)
      end

      # Build URI from URL and parameters and check it is http or https, encode array [] parameters
      def build_uri(url, query_hash=nil)
        uri = URI.parse(url)
        Aspera.assert(%w[http https].include?(uri.scheme)){"REST endpoint shall be http/s not #{uri.scheme}"}
        return uri if query_hash.nil?
        Log.log.debug{Log.dump('query', query_hash)}
        Aspera.assert_type(query_hash, Hash)
        return uri if query_hash.empty?
        query = []
        query_hash.each do |k, v|
          case v
          when Array
            # support array for query parameter, there is no standard. Either p[]=1&p[]=2, or p=1&p=2
            suffix = array_params?(v) ? v.shift : ''
            v.each do |e|
              query.push(["#{k}#{suffix}", e])
            end
          else
            query.push([k, v])
          end
        end
        # [] is allowed in url parameters
        uri.query = URI.encode_www_form(query).gsub('%5B%5D=', '[]=')
        return uri
      end

      # decode query string as hash
      # Does not support arrays in query string, no standard, e.g. PHP's way is p[]=1&p[]=2
      # @param query [String] query string
      # @return [Hash] decoded query
      def decode_query(query)
        URI.decode_www_form(query).each_with_object({}) do |pair, h|
          key = pair.first
          raise "Array not supported in query string: #{key}" if key.include?('[]') || h.key?(key)
          h[key] = pair.last
        end
      end

      # Start a HTTP/S session, also used for web sockets
      # @param base_url [String] base url of HTTP/S session
      # @return [Net::HTTP] a started HTTP session
      def start_http_session(base_url)
        uri = build_uri(base_url)
        # this honors http_proxy env var
        http_session = Net::HTTP.new(uri.host, uri.port)
        http_session.use_ssl = uri.scheme.eql?('https')
        # set http options in callback, such as timeout and cert. verification
        @@global[:session_cb]&.call(http_session)
        # manually start session for keep alive (if supported by server, else, session is closed every time)
        http_session.start
        return http_session
      end

      # get Net::HTTP underlying socket i/o
      # little hack, handy because HTTP debug, proxy, etc... will be available
      # used implement web sockets after `start_http_session`
      def io_http_session(http_session)
        Aspera.assert_type(http_session, Net::HTTP)
        # Net::BufferedIO in net/protocol.rb
        result = http_session.instance_variable_get(:@socket)
        Aspera.assert(!result.nil?){"no socket for #{http_session}"}
        return result
      end

      # @return [String] PEM certificates of remote server
      def remote_certificate_chain(url, as_string: true)
        result = []
        # initiate a session to retrieve remote certificate
        http_session = Rest.start_http_session(url)
        begin
          # retrieve underlying openssl socket
          result = Rest.io_http_session(http_session).io.peer_cert_chain
        rescue
          result = http_session.peer_cert
        ensure
          http_session.finish
        end
        result = result.map(&:to_pem).join("\n") if as_string
        return result
      end

      # set global parameters
      def set_parameters(**options)
        options.each do |key, value|
          Aspera.assert(@@global.key?(key)){"Unknown Rest option #{key}"}
          @@global[key] = value
        end
      end

      # @return [String] HTTP agent name
      def user_agent
        return @@global[:user_agent]
      end

      def parse_header(header)
        type, *params = header.split(/;\s*/)
        parameters = params.map do |param|
          one = param.split(/=\s*/)
          one[0] = one[0].to_sym
          one[1] = one[1].gsub(/\A"|"\z/, '')
          one
        end.to_h
        { type: type.downcase, parameters: parameters }
      end
    end

    private

    # create and start keep alive connection on demand
    def http_session
      if @http_session.nil?
        @http_session = self.class.start_http_session(@base_url)
      end
      return @http_session
    end

    public

    attr_reader :auth_params
    attr_reader :base_url

    def params
      return {
        base_url:       @base_url,
        auth:           @auth_params,
        not_auth_codes: @not_auth_codes,
        redirect_max:   @redirect_max,
        headers:        @headers
      }
    end

    # @param base_url [String] base URL of REST API
    # @param auth [Hash] authentication parameters:
    #     :type (:none, :basic, :url, :oauth2)
    #     :username   [:basic]
    #     :password   [:basic]
    #     :url_query  [:url]    a hash
    #     :*          [:oauth2] see OAuth::Factory class
    # @param not_auth_codes [Array] codes that trigger a refresh/regeneration of bearer token
    # @param redirect_max [int] max redirection allowed
    def initialize(
      base_url:,
      auth: nil,
      not_auth_codes: nil,
      redirect_max: 0,
      headers: nil
    )
      Aspera.assert_type(base_url, String)
      # base url with max one trailing slashes (note: string may be frozen)
      @base_url = base_url.gsub(%r{//+$}, '/')
      # default is no auth
      @auth_params = auth.nil? ? {type: :none} : auth
      Aspera.assert_type(@auth_params, Hash)
      Aspera.assert(@auth_params.key?(:type)){'no auth type defined'}
      @not_auth_codes = not_auth_codes.nil? ? ['401'] : not_auth_codes
      Aspera.assert_type(@not_auth_codes, Array)
      # persistent session
      @http_session = nil
      # OAuth object (created on demand)
      @oauth = nil
      @redirect_max = redirect_max
      @headers = headers.nil? ? {} : headers
      Aspera.assert_type(@headers, Hash)
      @headers['User-Agent'] ||= @@global[:user_agent]
    end

    # @return the OAuth object (create, or cached if already created)
    def oauth
      if @oauth.nil?
        Aspera.assert(@auth_params[:type].eql?(:oauth2)){'no OAuth defined'}
        oauth_parameters = @auth_params.reject { |k, _v| k.eql?(:type) }
        Log.log.debug{Log.dump('oauth parameters', oauth_parameters)}
        @oauth = OAuth::Factory.instance.create(**oauth_parameters)
      end
      return @oauth
    end

    # HTTP/S REST call
    # @param operation [String] HTTP operation (GET, POST, PUT, DELETE)
    # @param subpath [String] subpath of REST API
    # @param query [Hash] URL parameters
    # @param body [Hash, String] body parameters
    # @param body_type [Symbol] type of body parameters (:json, :www, :text, nil)
    # @param save_to_file (filepath)
    # @param return_error (bool)
    # @param headers [Hash] additional headers
    def call(
      operation:,
      subpath: nil,
      query: nil,
      body: nil,
      body_type: nil,
      save_to_file: nil,
      return_error: false,
      headers: nil
    )
      subpath = subpath.to_s if subpath.is_a?(Symbol)
      subpath = '' if subpath.nil?
      Aspera.assert_type(subpath, String)
      if headers.nil?
        headers = @headers.clone
      else
        h = headers
        headers = @headers.clone
        headers.merge!(h)
      end
      Aspera.assert_type(headers, Hash)
      Log.log.debug{"#{operation} [#{subpath}]".red.bold.bg_green}
      case @auth_params[:type]
      when :none
        # no auth
      when :basic
        Log.log.debug('using Basic auth')
        # done in build_req
      when :oauth2
        headers['Authorization'] = oauth.token unless headers.key?('Authorization')
      when :url
        query ||= {}
        @auth_params[:url_query].each do |key, value|
          query[key] = value
        end
      else Aspera.error_unexpected_value(@auth_params[:type])
      end
      result = {http: nil}
      # start a block to be able to retry the actual HTTP request in case of OAuth token expiration
      begin
        # TODO: shall we percent encode subpath (spaces) test with access key delete with space in id
        # URI.escape()
        separator = !['', '/'].include?(subpath) || @base_url.end_with?('/') ? '/' : ''
        uri = self.class.build_uri("#{@base_url}#{separator}#{subpath}", query)
        Log.log.debug{"URI=#{uri}"}
        begin
          # instantiate request object based on string name
          req = Net::HTTP.const_get(operation.capitalize).new(uri)
        rescue NameError
          raise "unsupported operation : #{operation}"
        end
        case body_type
        when :json
          req.body = JSON.generate(body) # , ascii_only: true
          req['Content-Type'] = 'application/json'
        when :www
          req.body = URI.encode_www_form(body)
          req['Content-Type'] = 'application/x-www-form-urlencoded'
        when :text
          req.body = body
          req['Content-Type'] = 'text/plain'
        when nil
        else
          raise "unsupported body type : #{body_type}"
        end
        # set headers
        headers.each do |key, value|
          req[key] = value
        end
        # :type = :basic
        req.basic_auth(@auth_params[:username], @auth_params[:password]) if @auth_params[:type].eql?(:basic)
        Log.log.debug{Log.dump(:req_body, req.body)}
        # we try the call, and will retry only if oauth, as we can, first with refresh, and then re-auth if refresh is bad
        oauth_tries ||= 2
        # initialize with number of initial retries allowed, nil gives zero
        tries_remain_redirect = @redirect_max.to_i if tries_remain_redirect.nil?
        Log.log.debug("send request (retries=#{tries_remain_redirect})")
        result_mime = nil
        file_saved = false
        # make http request (pipelined)
        http_session.request(req) do |response|
          result[:http] = response
          result_mime = self.class.parse_header(result[:http]['Content-Type'] || 'text/plain')[:type]
          # JSON data needs to be parsed, in case it contains an error code
          if !save_to_file.nil? &&
              result[:http].code.to_s.start_with?('2') &&
              !result[:http]['Content-Length'].nil? &&
              !JSON_DECODE.include?(result_mime)
            total_size = result[:http]['Content-Length'].to_i
            Log.log.debug('before write file')
            target_file = save_to_file
            # override user's path to path in header
            if !response['Content-Disposition'].nil?
              disposition = self.class.parse_header(response['Content-Disposition'])
              if disposition[:parameters].key?(:filename)
                target_file = File.join(File.dirname(target_file), disposition[:parameters][:filename])
              end
            end
            # download with temp filename
            target_file_tmp = "#{target_file}#{@@global[:download_partial_suffix]}"
            Log.log.debug{"saving to: #{target_file}"}
            written_size = 0
            @@global[:progress_bar]&.event(session_id: 1, type: :session_start)
            @@global[:progress_bar]&.event(session_id: 1, type: :session_size, info: total_size)
            File.open(target_file_tmp, 'wb') do |file|
              result[:http].read_body do |fragment|
                file.write(fragment)
                written_size += fragment.length
                @@global[:progress_bar]&.event(session_id: 1, type: :transfer, info: written_size)
              end
            end
            @@global[:progress_bar]&.event(session_id: 1, type: :end)
            # rename at the end
            File.rename(target_file_tmp, target_file)
            file_saved = true
          end
        end
        # sometimes there is a UTF8 char (e.g. (c) ), TODO : related to mime type encoding ?
        # result[:http].body.force_encoding('UTF-8') if result[:http].body.is_a?(String)
        # Log.log.debug{"result: body=#{result[:http].body}"}
        result[:data] = case result_mime
        when *JSON_DECODE
          JSON.parse(result[:http].body) rescue result[:http].body
        else # when 'text/plain'
          result[:http].body
        end
        Log.log.debug{"result: code=#{result[:http].code} mime=#{result_mime}"}
        Log.log.debug{Log.dump('data', result[:data])}
        RestErrorAnalyzer.instance.raise_on_error(req, result)
        File.write(save_to_file, result[:http].body) unless file_saved || save_to_file.nil?
      rescue RestCallError => e
        # not authorized: oauth token expired
        if @not_auth_codes.include?(result[:http].code.to_s) && @auth_params[:type].eql?(:oauth2)
          begin
            # try to use refresh token
            req['Authorization'] = oauth.token(refresh: true)
          rescue RestCallError => e_tok
            e = e_tok
            Log.log.error('refresh failed'.bg_red)
            # regenerate a brand new token
            req['Authorization'] = oauth.token(refresh: true)
          end
          Log.log.debug{"using new token=#{headers['Authorization']}"}
          retry if (oauth_tries -= 1).nonzero?
        end
        # redirect ? (any code beginning with 3)
        if e.response.is_a?(Net::HTTPRedirection) && tries_remain_redirect.positive?
          tries_remain_redirect -= 1
          current_uri = URI.parse(@base_url)
          new_url = e.response['location']
          # special case: relative redirect
          if URI.parse(new_url).host.nil?
            # we don't manage relative redirects with non-absolute path
            Aspera.assert(new_url.start_with?('/')){"redirect location is relative: #{new_url}, but does not start with /."}
            new_url = "#{current_uri.scheme}://#{current_uri.host}#{new_url}"
          end
          # forwards the request to the new location
          return self.class.new(base_url: new_url, redirect_max: tries_remain_redirect).call(
            operation: operation, query: query, body: body, body_type: body_type,
            save_to_file: save_to_file, return_error: return_error, headers: headers)
        end
        # raise exception if could not retry and not return error in result
        raise e unless return_error
      end
      Log.log.debug{"result=#{result}"}
      return result
    end

    #
    # CRUD methods here
    #

    def create(subpath, params)
      return call(operation: 'POST', subpath: subpath, headers: {'Accept' => 'application/json'}, body: params, body_type: :json)
    end

    def read(subpath, query=nil)
      return call(operation: 'GET', subpath: subpath, headers: {'Accept' => 'application/json'}, query: query)
    end

    def update(subpath, params)
      return call(operation: 'PUT', subpath: subpath, headers: {'Accept' => 'application/json'}, body: params, body_type: :json)
    end

    def delete(subpath, params=nil)
      return call(operation: 'DELETE', subpath: subpath, headers: {'Accept' => 'application/json'}, query: params)
    end

    def cancel(subpath)
      return call(operation: 'CANCEL', subpath: subpath, headers: {'Accept' => 'application/json'})
    end

    # Query entity by general search (read with parameter `q`)
    # TODO: not generic enough ? move somewhere ? inheritance ?
    # @param subpath path of entity in API
    # @param search_name name of searched entity
    # @param query additional search query parameters
    # @returns [Hash] A single entity matching the search, or an exception if not found or multiple found
    def lookup_by_name(subpath, search_name, query={})
      # returns entities matching the query (it matches against several fields in case insensitive way)
      matching_items = read(subpath, query.merge({'q' => search_name}))[:data]
      # API style: {totalcount:, ...} cspell: disable-line
      matching_items = matching_items[subpath] if matching_items.is_a?(Hash)
      Aspera.assert_type(matching_items, Array)
      case matching_items.length
      when 1 then return matching_items.first
      when 0 then raise %Q{#{ENTITY_NOT_FOUND} #{subpath}: "#{search_name}"}
      else
        # multiple case insensitive partial matches, try case insensitive full match
        # (anyway AoC does not allow creation of 2 entities with same case insensitive name)
        name_matches = matching_items.select{|i|i['name'].casecmp?(search_name)}
        case name_matches.length
        when 1 then return name_matches.first
        when 0 then raise %Q(#{subpath}: multiple case insensitive partial match for: "#{search_name}": #{matching_items.map{|i|i['name']}} but no case insensitive full match. Please be more specific or give exact name.) # rubocop:disable Layout/LineLength
        else raise "Two entities cannot have the same case insensitive name: #{name_matches.map{|i|i['name']}}"
        end
      end
    end
  end
end
