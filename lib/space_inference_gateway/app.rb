# frozen_string_literal: true

require "json"
require_relative "metrics"
require_relative "generation_observer"
require_relative "oai_normalizer"
require_relative "model_registry"
require_relative "model_controller"
require_relative "upstream_client"
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
    # Owns the upstream HTTP client and closes it when the body is done.
    # on_close is called once on first close (generation lifetime hook).
    #
    # The upstream normalizer is drained in a fiber-scheduler fiber and its
    # chunks are written to an IO pipe. #each reads from the pipe with a
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
    StreamBody = Struct.new(:response, :client, :normalizer, :on_close, :t0, :observer) do
      def each
        read_io, write_io = IO.pipe
        @read_io  = read_io
        @write_io = write_io

        # Drain the upstream normalizer in a scheduled fiber. Chunks are
        # written to the pipe; closing the write end on exit signals EOF.
        # An idle-gap timeout mid-stream (upstream silent past
        # UPSTREAM_IDLE_TIMEOUT) surfaces as IO::TimeoutError here — counted
        # separately from a downstream-abandon close (plain IOError) so it's
        # observable in /metrics even though the SSE stream, already 200'd,
        # can only end silently rather than carry a 5xx.
        Fiber.scheduler.fiber do
          normalizer.stream_to_sse(response.body, observer: observer) { |chunk| write_io.write(chunk) }
        rescue IO::TimeoutError
          Metrics::UPSTREAM_ERRORS.increment(labels: { status: "504" })
        rescue StandardError
          nil
        ensure
          write_io.close unless write_io.closed?
        end

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

      # Single idempotent teardown: upstream response closed before client (so
      # client#close's pool-drain wait returns promptly instead of hanging on
      # the still-checked-out connection), both pipe ends closed, duration
      # observed, and the generation counter released — exactly once. The
      # counter release runs under ensure (AC8): a raise anywhere above it
      # (response/client close, metrics) must not leak @active_generations.
      def close
        return if @closed

        @closed = true
        begin
          response.close
          client&.close
          @read_io&.close unless @read_io&.closed?
          @write_io&.close unless @write_io&.closed?
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
    # upstream_client: optional UpstreamClient — injected test seam; wins over default.
    # controller:      optional ModelController — built from config/models.yml when omitted.
    # error_relay:     optional ErrorRelay::Oai/Mlx instance — injected for testing.
    def initialize(upstream_fn: nil, upstream_client: nil, controller: nil, error_relay: nil)
      @upstream_fn     = upstream_fn
      @controller      = controller || build_default_controller
      @upstream_client = upstream_client || UpstreamClient.new(base_url: -> { @controller.base_url })
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

    private

    def handle_oai(env)
      t0          = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]
      streaming   = request["stream"] == true

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
        return open_stream("/v1/chat/completions", body_str, normalizer, t0: t0)
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
    def open_stream(path, body_str, normalizer, t0:)
      succeeded = false
      response, client = @upstream_client.open_stream(path, body_str)
      @controller.note_generation_success
      if response.status == 200
        observer  = GenerationObserver.new(t0: t0)
        on_close  = -> { @controller.end_generation }
        succeeded = true
        [200, SSE_HEADERS.dup, StreamBody.new(response, client, normalizer, on_close, t0, observer)]
      else
        @error_relay.relay(response.status, response.read.tap { client.close })
      end
    rescue IO::TimeoutError, Async::TimeoutError => e
      @controller.note_generation_failure
      @error_relay.relay(504, e.message)
    rescue StandardError
      upstream_error(502)
    ensure
      @controller.end_generation unless succeeded
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

    def effective_model(alias_name)
      @controller.registry.resolve(alias_name) ? alias_name : @advertised_model
    end

    # True when the entry for alias_name (or the default) uses one of the
    # OAI-upstream engines — see OAI_UPSTREAM_ENGINES.
    def mlx_engine?(alias_name)
      entry = @controller.registry.resolve(alias_name) ||
              @controller.registry.resolve(@controller.registry.default_alias)
      OAI_UPSTREAM_ENGINES.include?(entry&.fetch(:engine, nil))
    end

    # The model id the mlx child expects in the request body's "model" field —
    # the HF repo id mlx_lm.server loaded via --model. mlx_lm.server validates
    # this field against its loaded model and tries to fetch unknown names from
    # HuggingFace, so the alias cannot be forwarded as-is (unlike llama-server,
    # which ignores it).
    def mlx_model_id(alias_name)
      entry = @controller.registry.resolve(alias_name) ||
              @controller.registry.resolve(@controller.registry.default_alias)
      entry[:model]
    end

    # Stop tokens from the registry entry (optional). Workaround for the
    # mlx_lm 0.31.3 eos-token-id stop bug — see models.yml comment.
    def mlx_stop_tokens(alias_name)
      entry = @controller.registry.resolve(alias_name) ||
              @controller.registry.resolve(@controller.registry.default_alias)
      entry[:stop_tokens]
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

    # Applies OAI-upstream request rewrites (see OAI_UPSTREAM_ENGINES):
    # - mlx and mlx-vlm: rewrites the "model" field to the HF repo id (both
    #   validate this field against their loaded model; optiq single-model
    #   mode accepts any value, so it is excluded).
    # - all three engines: normalizes "developer" role to "system" and injects stop_tokens.
    def rewrite_model_for_mlx(body_str, model_alias)
      return body_str unless mlx_engine?(model_alias)

      parsed = JSON.parse(body_str)
      entry  = @controller.registry.resolve(model_alias) ||
               @controller.registry.resolve(@controller.registry.default_alias)
      parsed["model"] = mlx_model_id(model_alias) if %w[mlx mlx-vlm].include?(entry&.fetch(:engine, nil))
      (parsed["messages"] || []).each { |m| m["role"] = "system" if m["role"] == "developer" }
      inject_mlx_stop_tokens(parsed, model_alias)
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
