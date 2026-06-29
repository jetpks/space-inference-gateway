# frozen_string_literal: true

require "json"
require "async"
require "async/semaphore"
require "dry/monads"

module LocalInferenceProxy
  class ModelController
    include Dry::Monads[:result]

    LOAD_TIMEOUT  = 300
    POLL_INTERVAL = 2

    attr_reader :registry

    def initialize(registry:, cp_fn: nil, upstream_client: nil,
                   load_timeout: LOAD_TIMEOUT, poll_interval: POLL_INTERVAL)
      @registry        = registry
      @cp_fn           = cp_fn
      @upstream_client = upstream_client
      @load_timeout    = load_timeout
      @poll_interval   = poll_interval
      @semaphore       = Async::Semaphore.new(1)
      @active_generations = 0
      @loading_model   = nil
      @active_mode     = { is_diffusion: false, supports_reasoning: true }
    end

    def models_list
      @registry.aliases.map do |a|
        { "id" => a, "object" => "model", "created" => 0, "owned_by" => "local" }
      end
    end

    def active_mode
      @active_mode.dup
    end

    # For unknown / nil aliases: Success() immediately (pass-through).
    # For known aliases: ensure it is the active model, swapping if needed.
    def ensure_active_if_known(alias_name)
      return Success() unless alias_name && @registry.resolve(alias_name)

      ensure_active(alias_name)
    end

    # Explicit load — Failure(:unknown_model) for unregistered aliases.
    def ensure_active(alias_name)
      entry = @registry.resolve(alias_name)
      return Failure(:unknown_model) unless entry

      status_r = fetch_status
      return status_r if status_r.failure?

      status = status_r.value!
      update_active_mode(status)
      return Success() if active_matches?(status, entry[:model_path])

      return Failure(:busy) if @active_generations.positive?

      return await_same_model_or_busy(entry[:model_path]) if @semaphore.blocking?

      @semaphore.acquire do
        perform_swap(entry)
      end
    end

    # Explicit unload endpoint — forwards {model_path} upstream.
    def unload(model_path)
      _, status, = cp_call("POST", "/v1/unload", JSON.generate({ "model_path" => model_path }))
      return Failure(:upstream_error) unless status == 200

      @active_mode = { is_diffusion: false, supports_reasoning: true }
      Success({ "status" => "unloaded", "model_path" => model_path })
    end

    # Proxied load-progress endpoint.
    def fetch_load_progress
      body, status, = cp_call("GET", "/v1/load-progress", nil)
      return Failure(:upstream_error) unless status == 200

      Success(JSON.parse(body))
    end

    def begin_generation
      @active_generations += 1
    end

    def end_generation
      @active_generations -= 1
    end

    # Track in-flight generations. Swap attempts see @active_generations > 0 and 409.
    def with_generation
      begin_generation
      yield
    ensure
      end_generation
    end

    private

    def await_same_model_or_busy(model_path)
      return Failure(:busy) unless @loading_model == model_path

      @semaphore.acquire { nil }
      status_r = fetch_status
      return Failure(:busy) if status_r.failure?

      active_matches?(status_r.value!, model_path) ? Success() : Failure(:busy)
    end

    def perform_swap(entry)
      @loading_model = entry[:model_path]

      load_body = build_load_request(entry)
      _, status, = cp_call("POST", "/v1/load", JSON.generate(load_body))

      unless [200, 202].include?(status)
        @loading_model = nil
        return Failure(:upstream_error)
      end

      result = await_readiness(entry[:model_path])
      @loading_model = nil

      if result.success?
        status_r = fetch_status
        update_active_mode(status_r.value!) if status_r.success?
      end

      result
    end

    def await_readiness(model_path)
      deadline = Time.now + @load_timeout

      loop do
        progress_r = fetch_load_progress
        if ready_from_progress?(progress_r)
          status_r = fetch_status
          return Success() if status_r.success? && active_matches?(status_r.value!, model_path)
        end

        remaining = deadline - Time.now
        return Failure(:timeout) if remaining <= 0

        sleep([@poll_interval, remaining].min)
      end
    end

    def ready_from_progress?(progress_r)
      progress_r.success? && progress_r.value!["fraction"].to_f >= 1.0
    end

    def active_matches?(status, model_path)
      active = status["active_model"].to_s
      active == model_path ||
        active.end_with?("/#{model_path}") ||
        active.end_with?(model_path)
    end

    def update_active_mode(status)
      @active_mode = {
        is_diffusion:       status["is_diffusion"] == true,
        supports_reasoning: status["supports_reasoning"] != false,
      }
    end

    def fetch_status
      body, status, = cp_call("GET", "/api/inference/status", nil)
      return Failure(:upstream_error) unless status == 200

      Success(JSON.parse(body))
    end

    def build_load_request(entry)
      req = { "model_path" => entry[:model_path] }
      req["gguf_variant"]   = entry[:gguf_variant]   if entry[:gguf_variant]
      req["max_seq_length"] = entry[:max_seq_length] if entry[:max_seq_length]
      req
    end

    def cp_call(method, path, body)
      return @cp_fn.call(method, path, body) if @cp_fn

      @upstream_client.call(method, path, body)
    end
  end
end
