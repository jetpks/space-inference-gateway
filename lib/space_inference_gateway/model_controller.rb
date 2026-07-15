# frozen_string_literal: true

require "dry/monads"
require_relative "metrics"

module SpaceInferenceGateway
  class ModelController
    include Dry::Monads[:result]

    attr_reader :registry

    def initialize(registry:, supervisor:)
      @registry           = registry
      @supervisor         = supervisor
      @active_generations = 0
    end

    def active_alias   = @supervisor.active_alias
    def child_pid      = @supervisor.pid
    def child_running? = @supervisor.running?

    def models_list
      @registry.aliases.map do |a|
        { "id" => a, "object" => "model", "created" => 0, "owned_by" => "local" }
      end
    end

    def active_mode
      entry    = @registry.resolve(@supervisor.active_alias)
      supports = entry ? entry[:supports_reasoning] != false : true
      { supports_reasoning: supports }
    end

    def base_url
      @supervisor.base_url
    end

    # Lazy auto-swap on the request's `model` field. Real clients (Claude Code,
    # opencode) send their own model names, not our registry aliases, so an
    # unknown/nil name must still be served: keep whatever is already running,
    # else start the default. A known alias swaps to it as before.
    def ensure_active_if_known(alias_name)
      return ensure_active(alias_name) if alias_name && @registry.resolve(alias_name)
      return Success() if @supervisor.running?

      ensure_active(@registry.default_alias)
    end

    # Explicit load — Failure(:unknown_model) for unregistered aliases.
    def ensure_active(alias_name)
      return Failure(:unknown_model) unless @registry.resolve(alias_name)
      return Success() if @supervisor.active_alias == alias_name && @supervisor.running?
      return Failure(:busy) if @active_generations.positive?

      result = map_supervisor_result(@supervisor.swap(to: alias_name))
      r_label = result.success? ? "success" : result.failure.to_s
      Metrics::SWAP_RESULTS.increment(labels: { operation: "load", result: r_label })
      result
    end

    # Stop the supervisor; return UNLOAD_RESPONSE-shaped Success.
    def unload(provided_path = nil)
      entry = @registry.resolve(@supervisor.active_alias)
      path  = entry&.fetch(:gguf, nil) || entry&.fetch(:model_path, nil) || provided_path.to_s
      @supervisor.stop
      Metrics::SWAP_RESULTS.increment(labels: { operation: "unload", result: "success" })
      Success({ "status" => "unloaded", "model_path" => path })
    end

    # Synthesize readiness from supervisor state (LOAD_PROGRESS-schema-valid).
    def fetch_load_progress
      if @supervisor.running?
        Success({ "phase" => "ready", "bytes_loaded" => 0, "bytes_total" => 0, "fraction" => 1.0 })
      else
        Success({ "phase" => nil, "bytes_loaded" => 0, "bytes_total" => 0, "fraction" => 0.0 })
      end
    end

    def begin_generation
      @active_generations += 1
      Metrics::ACTIVE_GENERATIONS.increment
    end

    def end_generation
      @active_generations -= 1
      Metrics::ACTIVE_GENERATIONS.decrement
    end

    def with_generation
      begin_generation
      yield
    ensure
      end_generation
    end

    private

    def map_supervisor_result(result)
      return Success() if result.success?

      case result.failure
      when :readiness_timeout then Failure(:timeout)
      when :unknown_model     then Failure(:unknown_model)
      else                         Failure(:upstream_error)
      end
    end
  end
end
