# frozen_string_literal: true

require "json"
require "async/http/client"
require "async/http/endpoint"
require_relative "oai_normalizer"
require_relative "ant_normalizer"

module LocalInferenceProxy
  class App
    ADVERTISED_MODEL = ENV.fetch("ADVERTISED_MODEL", "local-inference")
    UPSTREAM_URL     = ENV.fetch("UPSTREAM_URL",     "http://127.0.0.1:8888")
    UPSTREAM_TOKEN   = ENV.fetch("UPSTREAM_TOKEN",   "")

    OAI_PATHS = %w[/v1/chat/completions].freeze
    ANT_PATHS = %w[/v1/messages].freeze

    JSON_HEADERS     = { "content-type" => "application/json" }.freeze
    SSE_HEADERS      = { "content-type" => "text/event-stream", "cache-control" => "no-cache",
"x-accel-buffering" => "no", }.freeze

    # upstream_fn: optional callable (env, body) => [status, headers, body_string]
    # Used in tests to inject a fake upstream without touching the network.
    def initialize(upstream_fn: nil)
      @upstream_fn      = upstream_fn
      @advertised_model = ADVERTISED_MODEL
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path   = env["PATH_INFO"]

      case [method, path]
      when ["POST", "/v1/chat/completions"]
        handle_oai(env)
      when ["POST", "/v1/messages"]
        handle_ant(env)
      when ["GET", "/v1/models"]
        handle_models
      else
        [404, JSON_HEADERS.dup, [JSON.generate({ error: { message: "Not found", type: "invalid_request_error" } })]]
      end
    rescue StandardError => e
      body = JSON.generate({ error: { message: e.message, type: "internal_error" } })
      [500, JSON_HEADERS.dup, [body]]
    end

    private

    def handle_oai(env)
      body_str = read_body(env)
      request  = JSON.parse(body_str)
      streaming = request["stream"] == true

      upstream_body, status, = call_upstream("/v1/chat/completions", body_str, env)
      return upstream_error(status) unless status == 200

      normalizer = OaiNormalizer.new(advertised_model: @advertised_model)

      if streaming
        sse = normalizer.normalize_stream_to_sse(upstream_body)
        [200, SSE_HEADERS.dup, [sse]]
      else
        parsed     = JSON.parse(upstream_body)
        normalized = normalizer.normalize(parsed)
        [200, JSON_HEADERS.dup, [JSON.generate(normalized)]]
      end
    end

    def handle_ant(env)
      body_str = read_body(env)
      request  = JSON.parse(body_str)
      streaming = request["stream"] == true

      upstream_body, status, _upstream_headers = call_upstream("/v1/messages", body_str, env)
      return upstream_error(status) unless status == 200

      normalizer = AntNormalizer.new(advertised_model: @advertised_model)

      if streaming
        sse = normalizer.normalize_stream_to_sse(upstream_body)
        [200, SSE_HEADERS.dup, [sse]]
      else
        parsed     = JSON.parse(upstream_body)
        normalized = normalizer.normalize(parsed)
        [200, JSON_HEADERS.dup, [JSON.generate(normalized)]]
      end
    end

    def handle_models
      body = JSON.generate({
                             "object" => "list",
        "data" => [{
          "id" => @advertised_model,
          "object" => "model",
          "created" => 0,
          "owned_by" => "local",
        }],
                           })
      [200, JSON_HEADERS.dup, [body]]
    end

    def call_upstream(path, body_str, env)
      if @upstream_fn
        @upstream_fn.call(path, body_str)
      else
        call_upstream_http(path, body_str, env)
      end
    end

    def call_upstream_http(path, body_str, _env)
      require "async"
      endpoint = Async::HTTP::Endpoint.parse("#{UPSTREAM_URL}#{path}")
      client   = Async::HTTP::Client.new(endpoint)

      headers = Protocol::HTTP::Headers.new
      headers["content-type"]  = "application/json"
      headers["authorization"] = "Bearer #{UPSTREAM_TOKEN}" unless UPSTREAM_TOKEN.empty?

      request  = Protocol::HTTP::Request.new("POST", path, headers, body_str)
      response = client.call(request)
      status   = response.status
      body     = response.read

      [body, status, {}]
    rescue StandardError => e
      [e.message, 502, {}]
    ensure
      client&.close
    end

    def read_body(env)
      input = env["rack.input"]
      input.rewind if input.respond_to?(:rewind)
      input.read
    end

    def upstream_error(status)
      body = JSON.generate({ error: { message: "Upstream returned #{status}", type: "upstream_error" } })
      [502, JSON_HEADERS.dup, [body]]
    end
  end
end
