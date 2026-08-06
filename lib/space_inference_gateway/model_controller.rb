# frozen_string_literal: true

require "async/semaphore"
require "dry/monads"
require_relative "metrics"

module SpaceInferenceGateway
  class ModelController
    include Dry::Monads[:result]

    # Consecutive generation-path failures — no response at all, from either
    # a streaming open (headers-phase timeout) or a buffered call (whole-call
    # timeout) — before restarting the active child. This is the
    # stream-agnostic request-path zombie watchdog (I04, widened I09): a
    # child that accepts TCP and answers /health but whose generate thread
    # has died will hang on every real request regardless of streaming, so
    # both App#open_stream and App#note_generation_outcome feed it. Any
    # response at all (any status, streaming or buffered) resets the count;
    # a stream that already opened and produced output before stalling
    # (mid-stream idle timeout) never touches it — see App::StreamBody.
    ZOMBIE_RESTART_THRESHOLD = Integer(ENV.fetch("ZOMBIE_RESTART_THRESHOLD", "2"))

    attr_reader :registry

    def initialize(registry:, supervisor:)
      @registry            = registry
      @supervisor          = supervisor
      @active_generations  = 0
      @zombie_streak       = 0
      # Serializes every engine-transition decision (active/busy check +
      # swap + generation reservation) so they are atomic with respect to
      # each other — the fix for both the swap TOCTOU (AC1) and the
      # cross-alias busy-guard race (AC2): a concurrent decision can only run
      # once the previous one (including its reservation, when it makes one)
      # has fully completed.
      @transition_gate = Async::Semaphore.new(1)
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

    # Lazy auto-swap on the request's `model` field, reserving a generation
    # slot atomically with the active/busy decision (AC2). Real clients
    # (Claude Code, opencode) send their own model names, not our registry
    # aliases, so an unknown/nil name must still be served: keep whatever is
    # already running, else start the default. A known alias swaps to it.
    def ensure_active_if_known(alias_name)
      return ensure_active(alias_name, reserve: true) if alias_name && @registry.resolve(alias_name)

      @transition_gate.acquire { ensure_running_default(reserve: true) }
    end

    # Explicit load — Failure(:unknown_model) for unregistered aliases.
    # reserve: true additionally counts a generation atomically with the
    # decision (used via #ensure_active_if_known above, for the request
    # path); POST /v1/load is a pure control-plane operation with no
    # generation to follow, so it uses the default reserve: false.
    def ensure_active(alias_name, reserve: false)
      return Failure(:unknown_model) unless @registry.resolve(alias_name)

      @transition_gate.acquire { ensure_active_locked(alias_name, reserve: reserve) }
    end

    # Stop the supervisor; return UNLOAD_RESPONSE-shaped Success.
    def unload(provided_path = nil)
      entry = @registry.resolve(@supervisor.active_alias)
      path  = entry&.fetch(:gguf, nil) || entry&.fetch(:model_path, nil) || provided_path.to_s
      @transition_gate.acquire { @supervisor.stop }
      Metrics::SWAP_RESULTS.increment(labels: { operation: "unload", result: "success" })
      Success({ "status" => "unloaded", "model_path" => path })
    end

    # Tears down the running engine for process shutdown (SIGTERM/SIGINT —
    # see bin/space-inference-gateway).
    def stop_engine
      @transition_gate.acquire { @supervisor.stop }
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

    # Resets the zombie-failure streak — any generation that receives a real
    # response, streaming (any status) or buffered (any status other than a
    # synthesized connection timeout), counts as evidence the child is alive.
    def note_generation_success
      @zombie_streak = 0
    end

    # Counts a generation-path failure — a streaming open that never
    # received headers, or a buffered call that timed out before a response
    # arrived. At ZOMBIE_RESTART_THRESHOLD consecutive occurrences, restarts
    # the active child directly through the supervisor's stop->spawn->
    # readiness machinery — bypassing the :busy guard, since a zombied child
    # dooms any in-flight generations anyway. The streak resets immediately
    # (before the restart's own await), so concurrent failures racing to the
    # threshold cannot stack restarts. A no-op if no child is running — the
    # lazy ensure-active path owns that case.
    def note_generation_failure
      return unless @supervisor.running?

      @zombie_streak += 1
      return if @zombie_streak < ZOMBIE_RESTART_THRESHOLD

      @zombie_streak = 0
      @transition_gate.acquire { restart_active_engine }
    end

    private

    def ensure_running_default(reserve:)
      if @supervisor.running?
        begin_generation if reserve
        return Success()
      end

      ensure_active_locked(@registry.default_alias, reserve: reserve)
    end

    # Runs inside @transition_gate: the active/busy decision, the transition,
    # and (when reserving) the generation count are atomic with respect to
    # every other decision. This closes the TOCTOU where a concurrent
    # cross-alias swap, admitted while nothing had been counted yet, would
    # only re-validate busy-ness at admission time and could still kill an
    # engine that gained a real generation while it waited its turn.
    def ensure_active_locked(alias_name, reserve:)
      if @supervisor.active_alias == alias_name && @supervisor.running?
        begin_generation if reserve
        return Success()
      end
      return Failure(:busy) if @active_generations.positive?

      result = map_supervisor_result(@supervisor.swap(to: alias_name))
      record_swap_metric("load", result)
      begin_generation if reserve && result.success?
      result
    end

    def restart_active_engine
      alias_name = @supervisor.active_alias
      result     = map_supervisor_result(@supervisor.swap(to: alias_name))
      record_swap_metric("zombie_restart", result)
      Metrics::CHILD_ZOMBIE_RESTARTS.increment
      result
    end

    def record_swap_metric(operation, result)
      label = result.success? ? "success" : result.failure.to_s
      Metrics::SWAP_RESULTS.increment(labels: { operation: operation, result: label })
    end

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
