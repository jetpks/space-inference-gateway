# frozen_string_literal: true

require "json"
require_relative "metrics"
require_relative "generation_observer"
require_relative "oai_normalizer"
require_relative "ant_normalizer"
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
    # ignored by the OpenAI + Anthropic SDK decoders (verified:
    # openai/core/streaming.js SSEDecoder returns null on `line.startsWith(':')`).
    #
    # The pipe + IO.select approach (rather than Async::Notification) is
    # required because Protocol::Rack::Body::Enumerable drives this body via
    # `to_enum(:each).next`, which runs #each in a separate Enumerator fiber
    # where Async::Task.current is unavailable. IO.select and Fiber.scheduler
    # work in any fiber on the scheduler's thread.
    StreamBody = Struct.new(:response, :client, :normalizer, :on_close, :flavor, :t0, :observer) do
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
          Metrics::UPSTREAM_ERRORS.increment(labels: { status: "504", flavor: flavor.to_s })
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
            Metrics::KEEPALIVE_COMMENTS.increment(labels: { flavor: flavor.to_s })
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
            labels: { flavor: flavor.to_s, stream: "true" },
          )
          observer&.close
        ensure
          on_close&.call
        end
      end
    end
    private_constant :StreamBody

    # Adapter: makes AntNormalizer#stream_to_sse_from_oai duck-type as stream_to_sse
    # so it can be dropped into StreamBody for the mlx ANT streaming path.
    OaiToAntAdapter = Struct.new(:normalizer) do
      def stream_to_sse(body, observer: nil, &block)
        normalizer.stream_to_sse_from_oai(body, observer: observer, &block)
      end
    end
    private_constant :OaiToAntAdapter

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
      when ["POST", "/v1/messages"]              then handle_ant(env)
      when ["POST", "/v1/messages/count_tokens"] then handle_count_tokens(env)
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

    # Engines that speak OpenAI HTTP only — the proxy synthesizes ANT for these
    # itself and never forwards /v1/messages to them: "mlx", "optiq", "mlx-vlm".
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
        record_request_accepted(flavor: "oai", streaming: streaming)
        return open_stream("/v1/chat/completions", body_str, normalizer, flavor: :oai, t0: t0)
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
                     record_oai_usage_and_stop(parsed, flavor: "oai")
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(parsed))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :oai)
                 end
      end
      observe_request(t0, flavor: "oai", streaming: streaming)
      result
    end

    def handle_ant(env)
      t0          = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]
      streaming   = request["stream"] == true
      mlx         = mlx_engine?(model_alias)

      # ANT->OAI translation runs before the reservation (AC1/I02): it can
      # raise on a JSON-parseable but ill-shaped body (e.g. a non-hash
      # message), and it only touches the registry — never the active/busy
      # decision — so nothing is lost by translating ahead of
      # ensure_active_if_known.
      if mlx
        entry    = resolve_mlx_entry(model_alias)
        oai_body = ant_to_oai(body_str, entry, stop_tokens: entry[:stop_tokens])
      end

      unless @upstream_fn # legacy test seam injects upstream directly; skip the supervisor
        swap_r = @controller.ensure_active_if_known(model_alias)
        return swap_error_response(swap_r.failure) if swap_r.failure?
      end

      mode       = @controller.active_mode
      normalizer = AntNormalizer.new(
        advertised_model:   effective_model(model_alias),
        supports_reasoning: mode[:supports_reasoning],
      )

      # mlx/optiq path instruments inside handle_ant_mlx
      return handle_ant_mlx(oai_body, normalizer, streaming) if mlx

      if streaming && @upstream_fn.nil?
        record_request_accepted(flavor: "ant", streaming: streaming)
        return open_stream("/v1/messages", body_str, normalizer, flavor: :ant, t0: t0)
      end

      result = nil
      with_active_generation do
        body_up, status, = call_upstream("/v1/messages", body_str)
        note_generation_outcome(status)
        result = if status == 200
                   if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(body_up)]]
                   else
                     parsed = JSON.parse(body_up)
                     record_ant_usage_and_stop(parsed, flavor: "ant")
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(parsed))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :ant)
                 end
      end
      observe_request(t0, flavor: "ant", streaming: streaming)
      result
    end

    def handle_ant_mlx(oai_body, normalizer, streaming)
      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      if streaming && @upstream_fn.nil?
        record_request_accepted(flavor: "ant", streaming: streaming)
        return open_stream("/v1/chat/completions", oai_body, OaiToAntAdapter.new(normalizer), flavor: :ant, t0: t0)
      end

      result = nil
      with_active_generation do
        body_up, status, = call_upstream("/v1/chat/completions", oai_body)
        note_generation_outcome(status)
        result = if status == 200
                   if streaming
                     sse = +""
                     normalizer.stream_to_sse_from_oai(Enumerator.new { |y| y << body_up }) { |s| sse << s }
                     [200, SSE_HEADERS.dup, [sse]]
                   else
                     parsed = JSON.parse(body_up)
                     record_oai_usage_and_stop(parsed, flavor: "ant")
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize_oai(parsed))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :ant)
                 end
      end
      observe_request(t0, flavor: "ant", streaming: streaming)
      result
    end

    def handle_models
      data = @controller.models_list
      body = JSON.generate({ "object" => "list", "data" => data })
      [200, JSON_HEADERS.dup, [body]]
    end

    # Anthropic count_tokens — mlx_lm.server has no native count_tokens, and CC
    # hits this before sending to size the prompt (a 404 makes CC refuse the
    # model as "may not exist"). Return a rough char-based estimate (~4 chars/token);
    # it is for the client's context-window accounting, not billing, so an
    # approximation is fine. Accepts the ANT request shape (system + messages +
    # tools), with content as a string or an array of content blocks.
    def handle_count_tokens(env)
      request = JSON.parse(read_body(env))
      chars = 0
      collect = lambda do |content|
        case content
        when String then chars += content.length
        when Array  then content.each { |blk| collect.call(blk["text"] || blk["content"] || "") }
        end
      end
      collect.call(request["system"]) if request["system"]
      (request["messages"] || []).each { |m| collect.call(m["content"]) }
      (request["tools"] || []).each { |t| collect.call(t.to_s) }
      [200, JSON_HEADERS.dup, [JSON.generate({ "input_tokens" => (chars / 4.0).ceil })]]
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
      [200, { "content-type" => Prometheus::Client::Formats::Text::CONTENT_TYPE }, [Metrics.render]]
    end

    # begin_generation already ran as part of ensure_active_if_known's
    # reservation (AC2) — the only caller of open_stream, always after that
    # call succeeded. This method owns the matching end_generation: once
    # (immediately below, on any non-success exit) or later, via StreamBody's
    # on_close, if the stream opens successfully.
    def open_stream(path, body_str, normalizer, flavor:, t0:)
      succeeded = false
      response, client = @upstream_client.open_stream(path, body_str)
      @controller.note_generation_success
      if response.status == 200
        observer  = GenerationObserver.new(flavor: flavor, t0: t0)
        on_close  = -> { @controller.end_generation }
        succeeded = true
        [200, SSE_HEADERS.dup, StreamBody.new(response, client, normalizer, on_close, flavor, t0, observer)]
      else
        @error_relay.relay(response.status, response.read.tap { client.close }, flavor: flavor)
      end
    rescue IO::TimeoutError, Async::TimeoutError => e
      @controller.note_generation_failure
      @error_relay.relay(504, e.message, flavor: flavor)
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

    def observe_request(t0, flavor:, streaming:)
      labels = { flavor: flavor, stream: streaming.to_s }
      Metrics::REQUESTS.increment(labels: labels)
      Metrics::REQUEST_DURATION.observe(Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0, labels: labels)
    end

    # Streaming accept-time counter only — duration is observed at stream
    # teardown (StreamBody#close), not here, since a streaming request's
    # useful duration is the whole generation, not the ms it took to open it.
    def record_request_accepted(flavor:, streaming:)
      Metrics::REQUESTS.increment(labels: { flavor: flavor, stream: streaming.to_s })
    end

    # Non-stream OAI-upstream usage/stop recording (AC3): usage.prompt_tokens/
    # completion_tokens and choices[0].finish_reason, both upstream-verbatim.
    def record_oai_usage_and_stop(parsed, flavor:)
      record_usage(parsed["usage"], prompt_key: "prompt_tokens", completion_key: "completion_tokens", flavor: flavor)
      finish = parsed.dig("choices", 0, "finish_reason")
      Metrics::GENERATION_STOPS.increment(labels: { flavor: flavor, stop_reason: finish.to_s }) if finish
    end

    # Non-stream ANT-native usage/stop recording (AC3): usage.input_tokens/
    # output_tokens and stop_reason, both upstream-verbatim.
    def record_ant_usage_and_stop(parsed, flavor:)
      record_usage(parsed["usage"], prompt_key: "input_tokens", completion_key: "output_tokens", flavor: flavor)
      stop = parsed["stop_reason"]
      Metrics::GENERATION_STOPS.increment(labels: { flavor: flavor, stop_reason: stop.to_s }) if stop
    end

    def record_usage(usage, prompt_key:, completion_key:, flavor:)
      return unless usage.is_a?(Hash)

      Metrics::USAGE_TOKENS.increment(by: usage[prompt_key].to_i, labels: { flavor: flavor, kind: "prompt" })
      Metrics::USAGE_TOKENS.increment(by: usage[completion_key].to_i, labels: { flavor: flavor, kind: "completion" })
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

    # Shared by inject_reasoning_effort (OAI) and ant_reasoning_effort (ANT):
    # a requested effort passes through if the template accepts it (or the
    # entry declares no allowlist); otherwise it coerces to the fallback.
    def coerce_reasoning_effort(requested, entry, fallback)
      allowed = Array(entry[:reasoning_effort_values]).map(&:to_s)
      requested && (allowed.empty? || allowed.include?(requested)) ? requested : fallback.to_s
    end

    # Anthropic-shape effort resolution for the ANT->OAI translation
    # (ant_to_oai). The client's opinion arrives as `thinking: {type:}` /
    # `output_config.effort`, not the OAI reasoning_effort field: disabled
    # thinking always wins (mlx-vlm turns "none" into enable_thinking=False
    # before the template's effort validation runs), otherwise a requested
    # effort is translated through the alias's reasoning_effort_map before
    # falling back to the shared allowed-values coercion. Entries with no
    # reasoning_effort default are untouched, matching inject_reasoning_effort.
    def ant_reasoning_effort(ant, entry)
      fallback = entry && entry[:reasoning_effort]
      return unless fallback
      return "none" if ant.dig("thinking", "type") == "disabled"

      requested = ant.dig("output_config", "effort")&.to_s
      return fallback.to_s unless requested

      mapped = entry[:reasoning_effort_map] && entry[:reasoning_effort_map][requested]
      mapped || coerce_reasoning_effort(requested, entry, fallback)
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
      (parsed["messages"] || []).each { |m| m["role"] = "system" if m["role"] == "developer" }
      inject_mlx_stop_tokens(parsed, model_alias)
      inject_reasoning_effort(parsed, entry)
      inject_sampling_penalties(parsed, entry)
      strip_history_reasoning(parsed) if entry && entry[:preserve_thinking] == false
      JSON.generate(parsed)
    end

    # Minimal ANT→OAI request translation for the mlx/optiq engine path.
    # mlx/optiq speak OAI only; system becomes messages[0]; fields mapped;
    # tool definitions, tool_result, and tool_use blocks are translated to
    # their OAI equivalents (see ant_message_to_oai / ant_tools_to_oai).
    def ant_to_oai(body_str, entry, stop_tokens: nil)
      ant  = JSON.parse(body_str)
      msgs = []
      msgs << { "role" => "system", "content" => ant["system"] } if ant["system"]
      # Claude Code 2.1.214+ sends mid-conversation system-role entries inside
      # messages[]; mlx/optiq reject any system message that isn't first, so
      # demote them to user (content preserved) — the top-level "system" field
      # above stays the only leading OAI system message.
      (ant["messages"] || []).each do |m|
        m["role"] = "user" if m["role"] == "system"
        ant_message_to_oai(m, msgs)
      end

      oai = { "model" => entry[:model], "messages" => msgs }
      oai["tools"]       = ant_tools_to_oai(ant["tools"]) if ant["tools"]
      oai["max_tokens"]  = ant["max_tokens"]  if ant.key?("max_tokens")
      oai["stream"]      = ant["stream"]      if ant.key?("stream")
      oai["temperature"] = ant["temperature"] if ant.key?("temperature")
      oai["top_p"]       = ant["top_p"]       if ant.key?("top_p")
      oai["stop"]        = ant["stop_sequences"] if ant.key?("stop_sequences")
      apply_ant_reasoning_effort(oai, ant, entry)
      merge_stop_tokens(oai, stop_tokens) if stop_tokens
      JSON.generate(oai)
    end

    def apply_ant_reasoning_effort(oai, ant, entry)
      effort = ant_reasoning_effort(ant, entry)
      oai["reasoning_effort"] = effort if effort
    end

    # ANT tools -> OAI tools (AC1). ANT: {name, description, input_schema}.
    def ant_tools_to_oai(tools)
      tools.map do |t|
        { "type" => "function",
          "function" => { "name" => t["name"], "description" => t["description"], "parameters" => t["input_schema"] }, }
      end
    end

    # Translates one ANT message into one or more OAI messages, appending to oai_msgs.
    # - user message with tool_result blocks (AC2): one OAI {role: tool} message per
    #   tool_result, plus a trailing {role: user} message for any leftover text.
    # - assistant message with tool_use blocks (AC3): a single OAI assistant message
    #   carrying both the flattened text (content) and the tool_calls array.
    # - everything else: content (string or text-block array) flattened to a string.
    def ant_message_to_oai(msg, oai_msgs)
      role    = msg["role"]
      content = msg["content"]
      blocks  = content.is_a?(Array) ? content : []
      types   = blocks.map { |b| b["type"] }

      if role == "user" && types.include?("tool_result")
        append_ant_tool_result_message(blocks, oai_msgs)
      elsif role == "assistant" && types.include?("tool_use")
        append_ant_tool_use_message(blocks, oai_msgs)
      else
        oai_msgs << { "role" => role, "content" => flatten_ant_text(content) }
      end
    end

    # AC2: a tool_result-bearing user message becomes one OAI {role: tool}
    # message per tool_result, plus a trailing {role: user} message for any
    # leftover (non-tool_result) text in the same ANT message.
    def append_ant_tool_result_message(blocks, oai_msgs)
      blocks.each do |block|
        next unless block["type"] == "tool_result"

        oai_msgs << { "role" => "tool", "tool_call_id" => block["tool_use_id"],
                      "content" => flatten_ant_text(block["content"]), }
      end
      text = flatten_ant_text(blocks.reject { |b| b["type"] == "tool_result" })
      oai_msgs << { "role" => "user", "content" => text } unless text.empty?
    end

    # AC3: a tool_use-bearing assistant message becomes a single OAI assistant
    # message carrying both the flattened text and the tool_calls array.
    def append_ant_tool_use_message(blocks, oai_msgs)
      text       = flatten_ant_text(blocks.reject { |b| b["type"] == "tool_use" })
      tool_calls = blocks.select { |b| b["type"] == "tool_use" }.map { |b| ant_tool_use_to_oai(b) }
      oai_msgs << { "role" => "assistant", "content" => text, "tool_calls" => tool_calls }
    end

    # ANT tool_use block -> OAI tool_calls entry (AC3). input is JSON-encoded
    # into function.arguments, the shape mlx/optiq expect.
    def ant_tool_use_to_oai(block)
      { "id" => block["id"], "type" => "function",
        "function" => { "name" => block["name"], "arguments" => JSON.generate(block["input"]) }, }
    end

    # Flattens ANT text content to a plain string: a string passes through;
    # an array of content blocks joins each block's "text" (non-text blocks,
    # e.g. tool_use/tool_result, contribute nothing — callers filter those out).
    def flatten_ant_text(content)
      case content
      when String then content
      when Array  then content.map { |b| b["text"].to_s }.join
      else ""
      end
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
