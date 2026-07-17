# frozen_string_literal: true

require "async/http/client"
require "async/http/endpoint"

module SpaceInferenceGateway
  # Shared HTTP client for upstream requests.
  # base_url accepts a String or any callable (#call → String); resolved per request.
  class UpstreamClient
    # Per-socket-operation (idle-gap) timeout, not a whole-request deadline: it
    # resets on every successful read/write, so a stream that keeps emitting
    # tokens never times out. Applied via Async::HTTP::Endpoint's timeout:
    # option, which sets IO#timeout= on the connection socket.
    #
    # Non-stream requests are bounded end-to-end by this timeout: their upstream
    # headers arrive only after full generation, so the whole call must fit in
    # one idle-gap window. Acceptable — the dev clients (pi/CC/opencode) all stream.
    UPSTREAM_IDLE_TIMEOUT = Integer(ENV.fetch("UPSTREAM_IDLE_TIMEOUT", "600"))

    def initialize(base_url:, token: "", idle_timeout: UPSTREAM_IDLE_TIMEOUT)
      @base_url     = base_url
      @token        = token
      @idle_timeout = idle_timeout
    end

    # Buffered call — suitable for control-plane and non-stream generations.
    # Returns [body_string, status, {}].
    def call(method, path, body_str = nil)
      client   = build_client
      request  = build_request(method, path, body_str)
      response = client.call(request)
      [response.read, response.status, {}]
    rescue IO::TimeoutError => e
      [e.message, 504, {}]
    rescue StandardError => e
      [e.message, 502, {}]
    ensure
      client&.close
    end

    # Opens a streaming request without buffering the body.
    # Returns [response, client]; caller MUST close the response then the client when done.
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
      url      = @base_url.respond_to?(:call) ? @base_url.call : @base_url
      endpoint = Async::HTTP::Endpoint.parse(url, timeout: @idle_timeout)
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
