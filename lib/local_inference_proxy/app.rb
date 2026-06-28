# frozen_string_literal: true

require "json"
require "async/http/client"
require "async/http/endpoint"
require_relative "oai_normalizer"
require_relative "ant_normalizer"
require_relative "model_registry"
require_relative "model_controller"

module LocalInferenceProxy
  class App
    ADVERTISED_MODEL = ENV.fetch("ADVERTISED_MODEL", "local-inference")
    UPSTREAM_URL     = ENV.fetch("UPSTREAM_URL",     "http://127.0.0.1:8888")
    UPSTREAM_TOKEN   = ENV.fetch("UPSTREAM_TOKEN",   "")

    JSON_HEADERS = { "content-type" => "application/json" }.freeze
    SSE_HEADERS  = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-cache",
      "x-accel-buffering" => "no",
    }.freeze

    # upstream_fn: optional (path, body) => [body, status, headers] — injected in tests.
    # controller:  optional ModelController — built from config/models.yml when omitted.
    def initialize(upstream_fn: nil, controller: nil)
      @upstream_fn      = upstream_fn
      @advertised_model = ADVERTISED_MODEL
      @controller       = controller || build_default_controller
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path   = env["PATH_INFO"]

      case [method, path]
      when ["POST", "/v1/chat/completions"] then handle_oai(env)
      when ["POST", "/v1/messages"]         then handle_ant(env)
      when ["GET",  "/v1/models"]           then handle_models
      when ["POST", "/v1/load"]             then handle_load(env)
      when ["POST", "/v1/unload"]           then handle_unload(env)
      when ["GET",  "/v1/load-progress"]    then handle_load_progress
      else
        [404, JSON_HEADERS.dup, [JSON.generate({ error: { message: "Not found", type: "invalid_request_error" } })]]
      end
    rescue StandardError => e
      body = JSON.generate({ error: { message: e.message, type: "internal_error" } })
      [500, JSON_HEADERS.dup, [body]]
    end

    private

    def handle_oai(env)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]

      swap_r = @controller.ensure_active_if_known(model_alias)
      return swap_error_response(swap_r.failure) if swap_r.failure?

      mode      = @controller.active_mode
      streaming = request["stream"] == true
      result    = nil

      @controller.with_generation do
        upstream_body, status, = call_upstream("/v1/chat/completions", body_str, env)
        if status == 200
          normalizer = OaiNormalizer.new(
            advertised_model:   effective_model(model_alias),
            supports_reasoning: mode[:supports_reasoning],
          )
          result = if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(upstream_body)]]
                   else
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(JSON.parse(upstream_body)))]]
                   end
        else
          result = upstream_error(status)
        end
      end

      result
    end

    def handle_ant(env)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]

      swap_r = @controller.ensure_active_if_known(model_alias)
      return swap_error_response(swap_r.failure) if swap_r.failure?

      mode      = @controller.active_mode
      streaming = request["stream"] == true
      result    = nil

      @controller.with_generation do
        upstream_body, status, = call_upstream("/v1/messages", body_str, env)
        if status == 200
          normalizer = AntNormalizer.new(
            advertised_model:   effective_model(model_alias),
            supports_reasoning: mode[:supports_reasoning],
          )
          result = if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(upstream_body)]]
                   else
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(JSON.parse(upstream_body)))]]
                   end
        else
          result = upstream_error(status)
        end
      end

      result
    end

    def handle_models
      data = @controller.models_list
      body = JSON.generate({ "object" => "list", "data" => data })
      [200, JSON_HEADERS.dup, [body]]
    end

    def handle_load(env)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"] || request["model_path"]

      result = @controller.ensure_active(model_alias.to_s)
      if result.success?
        entry = @controller.registry.resolve(model_alias.to_s)
        body  = JSON.generate({ "status" => "loaded", "model_path" => entry[:model_path] })
        [200, JSON_HEADERS.dup, [body]]
      else
        swap_error_response(result.failure)
      end
    end

    def handle_unload(env)
      body_str   = read_body(env)
      request    = JSON.parse(body_str)
      model_path = request["model_path"].to_s

      result = @controller.unload(model_path)
      if result.success?
        [200, JSON_HEADERS.dup, [JSON.generate(result.value!)]]
      else
        upstream_error(502)
      end
    end

    def handle_load_progress
      result = @controller.fetch_load_progress
      if result.success?
        [200, JSON_HEADERS.dup, [JSON.generate(result.value!)]]
      else
        upstream_error(502)
      end
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

    def swap_error_response(failure)
      case failure
      when :busy
        body = JSON.generate({ error: { message: "Model swap refused: generation in flight or swap in progress",
                                        type:    "model_busy", } })
        [409, JSON_HEADERS.dup, [body]]
      when :unknown_model
        body = JSON.generate({ error: { message: "Unknown model alias", type: "invalid_request_error" } })
        [422, JSON_HEADERS.dup, [body]]
      when :timeout
        body = JSON.generate({ error: { message: "Model load timed out", type: "upstream_error" } })
        [504, JSON_HEADERS.dup, [body]]
      else
        body = JSON.generate({ error: { message: "Upstream error during model swap", type: "upstream_error" } })
        [502, JSON_HEADERS.dup, [body]]
      end
    end

    def effective_model(alias_name)
      @controller.registry.resolve(alias_name) ? alias_name : @advertised_model
    end

    def build_default_controller
      registry = ModelRegistry.load
      ModelController.new(registry: registry)
    end
  end
end
