# frozen_string_literal: true

require "json"
require_relative "metrics"
require_relative "generation_observer"
require_relative "oai_normalizer"
require_relative "model_registry"
require_relative "model_controller"
require_relative "upstream_client"
require_relative "raw_completions_streamer"
require_relative "inference_server_supervisor"
require_relative "error_relay"

module SpaceInferenceGateway
  class App # rubocop:disable Metrics/ClassLength
    ADVERTISED_MODEL = ENV.fetch("ADVERTISED_MODEL", "local-inference")

    JSON_HEADERS = { "content-type" => "application/json" }.freeze
    SSE_HEADERS = {
      "content-type" => "text/event-stream",
      "cache-control" => "no-cache",
      "x-accel-buffering" => "no",
    }.freeze

    KEEPALIVE_INTERVAL = 8 # seconds — well under pi's 300s HTTP idle timeout
    KEEPALIVE_COMMENT = ": keepalive\n\n"

    # Streaming Rack body for SSE generation paths.
    # Owns the raw-stream session and closes it when the body is done.
    # on_close is called once on first close (generation lifetime hook).
    #
    # The session's drain task normalizes raw-surface events and writes the
    # downstream SSE bytes to an IO pipe. #each reads from the pipe with a
    # KEEPALIVE_INTERVAL timeout via IO.select, yielding an SSE comment
    # (`: keepalive\n\n`) on timeout. This keeps the client's HTTP idle timer
    # from tripping while the upstream is silent — e.g. optiq spends minutes in
    # prompt prefill emitting zero bytes, which would otherwise abort the stream
    # (pi defaults to a 300s idle timeout). Comment lines are SSE-spec-legal and
    # ignored by the OpenAI SDK decoders (verified:
    # openai/core/streaming.js SSEDecoder returns null on `line.startsWith(':')`).
    #
    # The pipe + IO.select approach (rather than Async::Notification) is
    # required because Protocol::Rack::Body::Enumerable drives this body via
    # `to_enum(:each).next`, which runs #each in a separate Enumerator fiber
    # where Async::Task.current is unavailable. IO.select and Fiber.scheduler
    # work in any fiber on the scheduler's thread.
    StreamBody = Struct.new(:session, :on_close, :t0, :observer) do
      def each
        read_io = session.read_io

        # Read from the pipe with a keepalive timeout. IO.select is
        # fiber-scheduler-aware and does not block the reactor.
        loop do
          if read_io.wait_readable(App::KEEPALIVE_INTERVAL).nil?
            yield App::KEEPALIVE_COMMENT
            Metrics::KEEPALIVE_COMMENTS.increment
          else
            data = read_io.read_nonblock(65_536, exception: false)
            break if data.nil? # EOF — upstream finished
            next if data == :wait_readable # spurious wakeup

            yield data unless data.empty?
          end
        end
      rescue StandardError
        nil
      ensure
        read_io.close unless read_io.closed?
      end

      # Single idempotent teardown: the raw-stream session aborted and both
      # pipe ends closed (the session owns the upstream connection — closing
      # it is the downstream-abandon signal the engine relies on to cancel
      # generation), duration observed, and the generation counter released —
      # exactly once. The counter release runs under ensure (AC8): a raise
      # anywhere above it (session close, metrics) must not leak
      # @active_generations.
      def close
        return if @closed

        @closed = true
        begin
          session.close
          Metrics::REQUEST_DURATION.observe(
            Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0,
            labels: { stream: "true" },
          )
          observer&.close
        ensure
          on_close&.call
        end
      end
    end
    private_constant :StreamBody

    # upstream_fn:     optional (path, body) => [body, status, headers] — legacy test seam.
    # upstream_client: optional UpstreamClient — injected test seam; wins over default
    #                  (control plane + buffered path).
    # raw_streamer:    optional RawCompletionsStreamer — injected test seam; wins over
    #                  default (streaming completions leg, I06/BRIEF §3).
    # controller:      optional ModelController — built from config/models.yml when omitted.
    # error_relay:     optional ErrorRelay::Oai/Mlx instance — injected for testing.
    def initialize(upstream_fn: nil, upstream_client: nil, raw_streamer: nil, controller: nil, error_relay: nil)
      @upstream_fn     = upstream_fn
      @controller      = controller || build_default_controller
      @upstream_client = upstream_client || UpstreamClient.new(base_url: -> { @controller.base_url })
      @raw_streamer    = raw_streamer || RawCompletionsStreamer.new(base_url: -> { @controller.base_url })
      @error_relay     = error_relay || default_error_relay
      @advertised_model = ADVERTISED_MODEL
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path   = env["PATH_INFO"]

      case [method, path]
      when ["POST", "/v1/chat/completions"]      then handle_oai(env)
      when ["GET",  "/v1/models"]                then handle_models
      when ["POST", "/v1/load"]                  then handle_load(env)
      when ["POST", "/v1/unload"]                then handle_unload(env)
      when ["GET",  "/v1/load-progress"]         then handle_load_progress
      when ["GET",  "/metrics"]                  then handle_metrics
      else
        [404, JSON_HEADERS.dup, [JSON.generate({ error: { message: "Not found", type: "invalid_request_error" } })]]
      end
    rescue StandardError => e
      body = JSON.generate({ error: { message: e.message, type: "internal_error" } })
      [500, JSON_HEADERS.dup, [body]]
    end

    # Tears down the running engine child — called on process shutdown
    # (SIGTERM/SIGINT; see bin/space-inference-gateway) so a gateway restart
    # doesn't orphan the (potentially ~80GB resident) engine process (AC7).
    def shutdown
      @controller.stop_engine
    end

    # Engines that speak OpenAI HTTP only — their quirks are absorbed at this
    # seam (request rewrites, error reshaping): "mlx", "optiq", "mlx-vlm".
    OAI_UPSTREAM_ENGINES = %w[mlx optiq mlx-vlm].freeze

    # Efforts that mean "no reasoning at all" rather than "less of it".
    # mlx-vlm reads these as a request to disable thinking, so they are a
    # legitimate client choice and pass through uncoerced.
    DISABLED_REASONING_EFFORTS = %w[none off disabled false 0].freeze

    private

    def handle_oai(env)
      t0          = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]
      streaming   = request["stream"] == true

      return model_resolution_error(model_alias) unless model_registered?(model_alias)

      # Body rewrite runs before the reservation (AC1/I02): it can raise on a
      # JSON-parseable but ill-shaped body (e.g. a non-hash message), and it
      # only touches the registry — never the active/busy decision — so
      # nothing is lost by validating/transforming ahead of ensure_active_if_known.
      body_str = rewrite_model_for_mlx(body_str, model_alias)

      unless @upstream_fn # legacy test seam injects upstream directly; skip the supervisor
        swap_r = @controller.ensure_active_if_known(model_alias)
        return swap_error_response(swap_r.failure) if swap_r.failure?
      end

      mode       = @controller.active_mode
      normalizer = OaiNormalizer.new(
        advertised_model:   effective_model(model_alias),
        supports_reasoning: mode[:supports_reasoning],
      )

      if streaming && @upstream_fn.nil?
        record_request_accepted(streaming: streaming)
        return open_stream(body_str, normalizer, t0: t0)
      end

      result = nil
      with_active_generation do
        body_up, status, = call_upstream("/v1/chat/completions", body_str)
        note_generation_outcome(status)
        result = if status == 200
                   if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(body_up)]]
                   else
                     parsed = JSON.parse(body_up)
                     record_oai_usage_and_stop(parsed)
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(parsed))]]
                   end
                 else
                   @error_relay.relay(status, body_up)
                 end
      end
      observe_request(t0, streaming: streaming)
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
        entry      = @controller.registry.resolve(model_alias.to_s)
        model_path = entry[:model] || entry[:gguf] || entry[:model_path]
        body       = JSON.generate({ "status" => "loaded", "model_path" => model_path.to_s })
        [200, JSON_HEADERS.dup, [body]]
      else
        swap_error_response(result.failure)
      end
    end

    def handle_unload(env)
      body_str   = read_body(env)
      request    = body_str.empty? ? {} : JSON.parse(body_str)
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

    def handle_metrics
      pid     = @controller.child_pid
      running = @controller.child_running?
      Metrics::CHILD_UP.set(running ? 1 : 0)
      Metrics::CHILD_PID.set((pid || 0).to_f)
      Metrics::CHILD_RSS_BYTES.set(Metrics.child_rss_bytes(pid).to_f)
      update_model_info_metric
      [200, { "content-type" => Fast::Prometheus::Formats::Text::CONTENT_TYPE }, [Metrics.render]]
    end

    # begin_generation already ran as part of ensure_active_if_known's
    # reservation (AC2) — the only caller of open_stream, always after that
    # call succeeded. This method owns the matching end_generation: once
    # (immediately below, on any non-success exit) or later, via StreamBody's
    # on_close, if the stream opens successfully.
    #
    # I06: the streaming leg rides the fast-completions raw surface via
    # @raw_streamer. The seam blocks until the upstream status is decided and
    # the first normalized chunk is in the pipe (so the 200-vs-error relay
    # split stays observable downstream exactly as before), then raises the
    # raw surface's own errors for the rescue ladder below — the phase-named
    # TimeoutError (TTFB watchdog) and ApiError (non-2xx, carrying status +
    # body for the relay) map onto the same responses the UpstreamClient
    # errors used to. The observer is created up front (its taps fire during
    # the open gate) and closed on failure so GENERATION_PHASE stays net-zero.
    def open_stream(body_str, normalizer, t0:)
      succeeded = false
      observer  = GenerationObserver.new(t0: t0)
      begin
        session = @raw_streamer.open(body_str, normalizer: normalizer, observer: observer)
        @controller.note_generation_success
        on_close = -> { @controller.end_generation }
        succeeded = true
        [200, SSE_HEADERS.dup, StreamBody.new(session, on_close, t0, observer)]
      rescue Fast::Completions::ApiError => e
        # A non-2xx response still proves the engine child is alive (headers
        # arrived) — the zombie-watchdog streak resets on it, exactly as the
        # pre-adoption open_stream did (note_generation_success ran on any
        # response before the status split).
        @controller.note_generation_success
        @error_relay.relay(e.status, e.body)
      rescue Fast::Completions::TimeoutError => e
        @controller.note_generation_failure
        @error_relay.relay(504, e.message)
      rescue StandardError
        upstream_error(502)
      ensure
        observer.close unless succeeded
        @controller.end_generation unless succeeded
      end
    end

    def call_upstream(path, body_str)
      if @upstream_fn
        @upstream_fn.call(path, body_str)
      else
        @upstream_client.call("POST", path, body_str)
      end
    end

    # The legacy upstream_fn test seam bypasses ensure_active_if_known
    # entirely (see #handle_oai), so it never reserves a generation slot;
    # it still owns the full begin/end pair via ModelController#with_generation.
    # The real supervisor-backed path already reserved the slot as part of
    # the swap decision (AC2), so only the release is needed here.
    def with_active_generation(&)
      if @upstream_fn
        @controller.with_generation(&)
      else
        begin
          yield
        ensure
          @controller.end_generation
        end
      end
    end

    # Feeds the stream-agnostic zombie watchdog (AC4) from the buffered
    # (non-stream) generation path: a synthesized connection timeout
    # (UpstreamClient#call's 504) counts as a failure, matching the
    # streaming path's headers-timeout signal; any real response resets it.
    def note_generation_outcome(status)
      if status == 504
        @controller.note_generation_failure
      else
        @controller.note_generation_success
      end
    end

    def observe_request(t0, streaming:)
      labels = { stream: streaming.to_s }
      Metrics::REQUESTS.increment(labels: labels)
      Metrics::REQUEST_DURATION.observe(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, labels: labels)
    end

    # Streaming accept-time counter only — duration is observed at stream
    # teardown (StreamBody#close), not here, since a streaming request's
    # useful duration is the whole generation, not the ms it took to open it.
    def record_request_accepted(streaming:)
      Metrics::REQUESTS.increment(labels: { stream: streaming.to_s })
    end

    # Non-stream OAI-upstream usage/stop recording (AC3): usage.prompt_tokens/
    # completion_tokens and choices[0].finish_reason, both upstream-verbatim.
    def record_oai_usage_and_stop(parsed)
      record_usage(parsed["usage"], prompt_key: "prompt_tokens", completion_key: "completion_tokens")
      finish = parsed.dig("choices", 0, "finish_reason")
      Metrics::GENERATION_STOPS.increment(labels: { stop_reason: finish.to_s }) if finish
    end

    def record_usage(usage, prompt_key:, completion_key:)
      return unless usage.is_a?(Hash)

      Metrics::USAGE_TOKENS.increment(by: usage[prompt_key].to_i, labels: { kind: "prompt" })
      Metrics::USAGE_TOKENS.increment(by: usage[completion_key].to_i, labels: { kind: "completion" })
    end

    def update_model_info_metric
      alias_name = @controller.active_alias
      return unless alias_name

      entry  = @controller.registry.resolve(alias_name)
      engine = entry&.fetch(:engine, "unknown") || "unknown"
      Metrics.update_model_info(alias_name.to_s, engine.to_s)
    end

    def read_body(env)
      input = env["rack.input"]
      return "" unless input

      input.rewind if input.respond_to?(:rewind)
      input.read.to_s
    end

    def upstream_error(status)
      body = JSON.generate({ error: { message: "Upstream returned #{status}", type: "upstream_error" } })
      [502, JSON_HEADERS.dup, [body]]
    end

    def swap_error_response(failure)
      case failure
      when :busy
        body = JSON.generate({ error: { message: "Model swap refused: generation in flight",
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

    # Strict model resolution on the two GENERATION endpoints. An absent or
    # unregistered alias is refused rather than served by whatever happens to
    # be running.
    #
    # The old fallback was deliberate — reference/http-api.md argued "real
    # clients send their own model names (claude-...), which won't match your
    # aliases — rather than 404, the gateway serves them." It is a measurement
    # hazard that outgrew that rationale. A request naming an unregistered
    # alias got a 200 and a coherent completion from a DIFFERENT model, with
    # nothing in the response saying so: `effective_model` echoes
    # ADVERTISED_MODEL, `resolve_mlx_entry` silently supplies the default
    # alias's entry, and `rewrite_model_for_mlx` forwards that entry's HF repo
    # id upstream. The alias, the echoed model and the forwarded weights can
    # all disagree at once. Measured 2026-09-01: a sweep for an alias the
    # running gateway predated wrote 19 records answered by Qwen3.8-27B-mxfp8.
    #
    # The premise is also no longer true. Clients pin every tier — foreground,
    # background classifiers, subagents — to one registered alias, precisely
    # so a background call cannot land on a different alias and thrash the
    # single-flight supervisor. Strictness DEFENDS that invariant: an unmapped
    # tier now fails loudly instead of silently swapping the child.
    def model_registered?(model_alias)
      named?(model_alias) && !@controller.registry.resolve(model_alias).nil?
    end

    def named?(model_alias)
      model_alias.is_a?(String) && !model_alias.strip.empty?
    end

    def model_resolution_error(model_alias)
      named   = named?(model_alias)
      status  = named ? 404 : 400
      message = if named
                  "Unknown model #{model_alias.inspect}. Name a registered alias; GET /v1/models lists them."
                else
                  "The 'model' field is required. Name a registered alias; GET /v1/models lists them."
                end
      [status, JSON_HEADERS.dup, [model_error_body(message, status)]]
    end

    # OAI error shape: nests under "error" with a code/param a client can
    # branch on.
    def model_error_body(message, status)
      error = { message: message, type: "invalid_request_error", param: "model" }
      error[:code] = "model_not_found" if status == 404
      JSON.generate({ error: error })
    end

    def effective_model(alias_name)
      @controller.registry.resolve(alias_name) ? alias_name : @advertised_model
    end

    # The registry entry for alias_name, falling back to the default alias's
    # entry for an unknown/unset alias (same fallback ensure_active_if_known
    # would resolve to, so the mlx-facing rewrites agree with what actually
    # loads).
    def resolve_mlx_entry(alias_name)
      @controller.registry.resolve(alias_name) ||
        @controller.registry.resolve(@controller.registry.default_alias)
    end

    # True when the entry for alias_name (or the default) uses one of the
    # OAI-upstream engines — see OAI_UPSTREAM_ENGINES.
    def mlx_engine?(alias_name)
      OAI_UPSTREAM_ENGINES.include?(resolve_mlx_entry(alias_name)&.fetch(:engine, nil))
    end

    # The model id the mlx child expects in the request body's "model" field —
    # the HF repo id mlx_lm.server loaded via --model. mlx_lm.server validates
    # this field against its loaded model and tries to fetch unknown names from
    # HuggingFace, so the alias cannot be forwarded as-is (unlike llama-server,
    # which ignores it).
    def mlx_model_id(alias_name)
      resolve_mlx_entry(alias_name)[:model]
    end

    # Stop tokens from the registry entry (optional). Workaround for the
    # mlx_lm 0.31.3 eos-token-id stop bug — see models.yml comment.
    def mlx_stop_tokens(alias_name)
      resolve_mlx_entry(alias_name)[:stop_tokens]
    end

    # Merge registry stop_tokens into the request's existing "stop" field,
    # de-duplicated. Mutates `parsed` in place.
    def inject_mlx_stop_tokens(parsed, model_alias)
      stop_tokens = mlx_stop_tokens(model_alias)
      return unless stop_tokens

      merge_stop_tokens(parsed, stop_tokens)
    end

    def merge_stop_tokens(body, stop_tokens)
      existing = Array(body["stop"])
      body["stop"] = (existing + Array(stop_tokens)).uniq
    end

    # mlx-vlm forwards reasoning_effort straight into apply_chat_template, so
    # the accepted vocabulary is the *model template's*, not OpenAI's.
    # Qwen3.8-Flash-Next raises on anything but xhigh/medium/low, which turns
    # a stock client's reasoning_effort: "high" into a 500 rather than a
    # degradation. An entry declares what its template accepts
    # (reasoning_effort_values) and what to fall back to (reasoning_effort);
    # an unsupported value is coerced to the fallback instead of relayed.
    #
    # Entries without a reasoning_effort default are untouched — this must
    # stay a no-op for every alias that predates it.
    def inject_reasoning_effort(parsed, entry)
      fallback = entry && entry[:reasoning_effort]
      return unless fallback

      requested = requested_reasoning_effort(parsed)
      return if requested && DISABLED_REASONING_EFFORTS.include?(requested.downcase)

      apply_reasoning_effort(parsed, coerce_reasoning_effort(requested, entry, fallback))
    end

    # Sampling penalties an alias declares are DEFAULTS, not overrides: a
    # client that states its own keeps it, matching how reasoning_effort
    # treats a value its template accepts. An alias declaring none is
    # untouched, so this stays a no-op for every alias that predates it.
    #
    # These reach the engine as request fields, which means they are applied
    # AFTER a client has recorded what it sent - an evaluation harness
    # logging its own request body will not see them. Anything comparing runs
    # across aliases has to read them from here, not from the client's log.
    def inject_sampling_penalties(parsed, entry)
      declared = entry && entry[:penalties]
      return unless declared.is_a?(Hash)

      declared.each do |key, value|
        name = key.to_s
        parsed[name] = value unless parsed.key?(name)
      end
    end

    # A client may express effort as either the flat reasoning_effort field or
    # the nested Responses-API reasoning: {effort:}. mlx-vlm checks the nested
    # form first, so both are read here and both are rewritten below.
    def requested_reasoning_effort(parsed)
      nested = parsed["reasoning"].is_a?(Hash) ? parsed["reasoning"]["effort"] : nil
      (parsed["reasoning_effort"] || nested)&.to_s
    end

    def apply_reasoning_effort(parsed, effort)
      parsed["reasoning_effort"] = effort
      parsed["reasoning"]["effort"] = effort if parsed["reasoning"].is_a?(Hash)
    end

    # Used by inject_reasoning_effort: a requested effort passes through if
    # the template accepts it (or the entry declares no allowlist); otherwise
    # it coerces to the fallback.
    def coerce_reasoning_effort(requested, entry, fallback)
      allowed = Array(entry[:reasoning_effort_values]).map(&:to_s)
      requested && (allowed.empty? || allowed.include?(requested)) ? requested : fallback.to_s
    end

    # Qwen-family templates replay each prior assistant turn's full
    # chain-of-thought back into the prompt unless preserve_thinking is false —
    # and it defaults true. That grows context by every past turn's reasoning
    # rather than by its answer, which is the wrong trade on a box where the
    # weights already own most of the wired limit. mlx-vlm does not forward
    # preserve_thinking to the template, so the equivalent is done here:
    # with the field gone, the template renders an empty think block for
    # history and the answers survive intact.
    def strip_history_reasoning(parsed)
      messages = parsed["messages"]
      return unless messages.is_a?(Array)

      messages.each do |message|
        message.delete("reasoning_content") if message.is_a?(Hash) && message["role"] == "assistant"
      end
    end

    # Applies OAI-upstream request rewrites (see OAI_UPSTREAM_ENGINES):
    # - mlx and mlx-vlm: rewrites the "model" field to the HF repo id (both
    #   validate this field against their loaded model; optiq single-model
    #   mode accepts any value, so it is excluded).
    # - all three engines: normalizes "developer" role to "system" and injects stop_tokens.
    def rewrite_model_for_mlx(body_str, model_alias)
      return body_str unless mlx_engine?(model_alias)

      parsed = JSON.parse(body_str)
      entry  = resolve_mlx_entry(model_alias)
      parsed["model"] = mlx_model_id(model_alias) if %w[mlx mlx-vlm].include?(entry&.fetch(:engine, nil))
      # Modern OAI clients (pi included) send max_completion_tokens; mlx-vlm's
      # schema only reads max_tokens and silently defaults to 2048 when it's
      # missing — xhigh thinking exhausts that before the answer begins. Fold
      # the modern field into the engine's; an explicit max_tokens always wins.
      # (Ported from prod f17acc5, I06.)
      if parsed.key?("max_completion_tokens") && !parsed.key?("max_tokens")
        parsed["max_tokens"] = parsed.delete("max_completion_tokens")
      end
      (parsed["messages"] || []).each { |m| m["role"] = "system" if m["role"] == "developer" }
      inject_mlx_stop_tokens(parsed, model_alias)
      inject_reasoning_effort(parsed, entry)
      inject_sampling_penalties(parsed, entry)
      strip_history_reasoning(parsed) if entry && entry[:preserve_thinking] == false
      JSON.generate(parsed)
    end

    def build_default_controller
      registry   = ModelRegistry.load
      supervisor = InferenceServerSupervisor.new(registry: registry)
      @default_registry = registry
      ModelController.new(registry: registry, supervisor: supervisor)
    end

    def default_error_relay
      entry = @controller.registry.resolve(@controller.registry.default_alias)
      OAI_UPSTREAM_ENGINES.include?(entry&.fetch(:engine, nil)) ? ErrorRelay::Mlx.new : ErrorRelay::Oai.new
    end
  end
end
