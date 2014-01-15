require 'cgi'
require 'oauth2'
require 'omniauth'
require 'securerandom'
require 'timeout'
require 'uri'

module OmniAuth
  module Strategies
    # Authentication strategy for connecting with APIs constructed using
    # the [OAuth 2.0 Specification](http://tools.ietf.org/html/draft-ietf-oauth-v2-10).
    # You must generally register your application with the provider and
    # utilize an application id and secret in order to authenticate using
    # OAuth 2.0.
    class OAuth2
      include OmniAuth::Strategy

      args [:client_id, :client_secret]

      option :client_id, nil
      option :client_secret, nil
      option :client_options, {}
      option :authorize_params, {}
      option :authorize_options, [:scope]
      option :token_params, {}
      option :token_options, []
      option :auth_token_params, {}
      option :provider_ignores_state, false

      attr_accessor :access_token

      def client
        ::OAuth2::Client.new(options.client_id, options.client_secret, deep_symbolize(options.client_options))
      end

      def callback_url
        full_host + script_name + callback_path
      end

      credentials do
        hash = {'token' => access_token.token}
        hash.merge!('refresh_token' => access_token.refresh_token) if access_token.expires? && access_token.refresh_token
        hash.merge!('expires_at' => access_token.expires_at) if access_token.expires?
        hash.merge!('expires' => access_token.expires?)
        hash
      end

      def request_phase
        redirect client.auth_code.authorize_url({:redirect_uri => callback_url}.merge(authorize_params))
      end

      def authorize_params
        options.authorize_params[:state] = SecureRandom.hex(24)
        params = options.authorize_params.merge(authorize_options)
        if OmniAuth.config.test_mode
          @env ||= {}
          @env['rack.session'] ||= {}
        end
        session['omniauth.state'] = params[:state]
        params
      end

      def token_params
        options.token_params.merge(token_options)
      end

      def callback_phase # rubocop:disable CyclomaticComplexity
        error = request.params['error_reason'] || request.params['error']
        if error
          fail!(error, CallbackError.new(request.params['error'], request.params['error_description'] || request.params['error_reason'], request.params['error_uri']))
        elsif !options.provider_ignores_state && (request.params['state'].to_s.empty? || request.params['state'] != session.delete('omniauth.state'))
          fail!(:csrf_detected, CallbackError.new(:csrf_detected, 'CSRF detected'))
        else
          self.access_token = build_access_token
          self.access_token = access_token.refresh! if access_token.expired?
          super
        end
      rescue ::OAuth2::Error, CallbackError => e
        fail!(:invalid_credentials, e)
      rescue ::MultiJson::DecodeError => e
        fail!(:invalid_response, e)
      rescue ::Timeout::Error, ::Errno::ETIMEDOUT, Faraday::Error::TimeoutError => e
        fail!(:timeout, e)
      rescue ::SocketError, Faraday::Error::ConnectionFailed => e
        fail!(:failed_to_connect, e)
      end

    protected

      def token_options
        options.token_options.inject({}) do |hash, key|
          hash[key.to_sym] = options[key] if options[key]
          hash
        end
      end

      def authorize_options
        options.authorize_options.inject({}) do |hash, key|
          hash[key.to_sym] = options[key] if options[key]
          hash
        end
      end

      def deep_symbolize(hash)
        hash.inject({}) do |h, (k, v)|
          h[k.to_sym] = v.is_a?(Hash) ? deep_symbolize(v) : v
          h
        end
      end

      def build_access_token
        verifier = request.params['code']
        client.auth_code.get_token(verifier, {:redirect_uri => callback_url}.merge(token_params.to_hash(:symbolize_keys => true)), deep_symbolize(options.auth_token_params))
      end

      # An error that is indicated in the OAuth 2.0 callback.
      # This could be a `redirect_uri_mismatch` or other
      class CallbackError < StandardError
        attr_accessor :error, :error_reason, :error_uri

        def initialize(error, error_reason = nil, error_uri = nil)
          self.error = error
          self.error_reason = error_reason
          self.error_uri = error_uri
        end

        def message
          [error, error_reason, error_uri].compact.join(' | ')
        end
      end
    end
  end
end

OmniAuth.config.add_camelization 'oauth2', 'OAuth2'
