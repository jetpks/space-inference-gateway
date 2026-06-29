# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"

module LocalInferenceProxy
  # Shared HTTP client for upstream (unsloth) requests.
  # Holds base_url + token so both App and ModelController
  # draw from the same injected config.
  class UpstreamClient
    def initialize(base_url:, token: "")
      @base_url = base_url
      @token    = token
    end

    # Buffered call — suitable for control-plane and non-stream generations.
    # Returns [body_string, status, {}].
    def call(method, path, body_str = nil)
      client  = build_client
      request = build_request(method, path, body_str)
      response = client.call(request)
      [response.read, response.status, {}]
    rescue StandardError => e
      [e.message, 502, {}]
    ensure
      client&.close
    end

    # Opens a streaming request without buffering the body.
    # Returns [response, client]; caller MUST close the client when done.
    def open_stream(path, body_str)
      client   = build_client
      request  = build_request("POST", path, body_str)
      response = client.call(request)
      [response, client]
    rescue StandardError
      client&.close
      raise
    end

    private

    def build_client
      endpoint = Async::HTTP::Endpoint.parse(@base_url)
      Async::HTTP::Client.new(endpoint)
    end

    def build_request(method, path, body_str)
      headers = Protocol::HTTP::Headers.new
      headers["content-type"]  = "application/json"
      headers["authorization"] = "Bearer #{@token}" unless @token.empty?
      Protocol::HTTP::Request[method, path, headers, body_str]
    end
  end
end
