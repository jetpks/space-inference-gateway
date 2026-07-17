# frozen_string_literal: true

require "dry/monads"
require_relative "metrics"

module SpaceInferenceGateway
  class ModelController
    include Dry::Monads[:result]

    # Consecutive streaming headers-phase timeouts (zero response bytes
    # received) before restarting the active child — the request-path zombie
    # watchdog (I04). Any successful stream open (headers received, any
    # status) resets the count; mid-stream idle timeouts, buffered-path
    # timeouts, and connection errors never touch it (see App#open_stream).
    ZOMBIE_RESTART_THRESHOLD = Integer(ENV.fetch("ZOMBIE_RESTART_THRESHOLD", "2"))

    attr_reader :registry

    def initialize(registry:, supervisor:)
      @registry           = registry
      @supervisor         = supervisor
      @active_generations = 0
      @zombie_streak      = 0
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

    # Resets the zombie-timeout streak — called whenever a streaming open
    # receives response headers, regardless of status code.
    def note_headers_received
      @zombie_streak = 0
    end

    # Counts a streaming headers-phase timeout. At ZOMBIE_RESTART_THRESHOLD
    # consecutive occurrences, restarts the active child directly through the
    # supervisor's stop->spawn->readiness machinery (serialized by its own
    # swap semaphore) — bypassing the :busy guard in #ensure_active above,
    # since a zombied child dooms any in-flight generations anyway. The
    # streak resets immediately (before the restart's own await), so
    # concurrent timeouts racing to the threshold cannot stack restarts. A
    # no-op if no child is running — the lazy ensure-active path owns that case.
    def note_headers_timeout
      return unless @supervisor.running?

      @zombie_streak += 1
      return if @zombie_streak < ZOMBIE_RESTART_THRESHOLD

      @zombie_streak = 0
      @supervisor.swap(to: @supervisor.active_alias)
      Metrics::CHILD_ZOMBIE_RESTARTS.increment
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
