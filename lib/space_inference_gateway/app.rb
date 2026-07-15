# frozen_string_literal: true

require "json"
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

    KEEPALIVE_INTERVAL = 45 # seconds — well under pi's 300s HTTP idle timeout
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
    StreamBody = Struct.new(:response, :client, :normalizer, :on_close) do
      def each
        read_io, write_io = IO.pipe

        # Drain the upstream normalizer in a scheduled fiber. Chunks are
        # written to the pipe; closing the write end on exit signals EOF.
        Fiber.scheduler.fiber do
          normalizer.stream_to_sse(response.body) { |chunk| write_io.write(chunk) }
        ensure
          write_io.close
        end

        # Read from the pipe with a keepalive timeout. IO.select is
        # fiber-scheduler-aware and does not block the reactor.
        loop do
          if read_io.wait_readable(App::KEEPALIVE_INTERVAL).nil?
            yield App::KEEPALIVE_COMMENT
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
        read_io.close
      end

      def close
        return if @closed

        @closed = true
        on_close&.call
        client&.close
      end
    end
    private_constant :StreamBody

    # Adapter: makes AntNormalizer#stream_to_sse_from_oai duck-type as stream_to_sse
    # so it can be dropped into StreamBody for the mlx ANT streaming path.
    OaiToAntAdapter = Struct.new(:normalizer) do
      def stream_to_sse(body, &block)
        normalizer.stream_to_sse_from_oai(body, &block)
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
      when ["POST", "/v1/chat/completions"] then handle_oai(env)
      when ["POST", "/v1/messages"]         then handle_ant(env)
      when ["POST", "/v1/messages/count_tokens"] then handle_count_tokens(env)
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
      streaming   = request["stream"] == true

      unless @upstream_fn # legacy test seam injects upstream directly; skip the supervisor
        swap_r = @controller.ensure_active_if_known(model_alias)
        return swap_error_response(swap_r.failure) if swap_r.failure?
      end

      mode       = @controller.active_mode
      normalizer = OaiNormalizer.new(
        advertised_model:   effective_model(model_alias),
        supports_reasoning: mode[:supports_reasoning],
      )

      body_str = rewrite_model_for_mlx(body_str, model_alias)

      return open_stream("/v1/chat/completions", body_str, normalizer, flavor: :oai) if streaming && @upstream_fn.nil?

      result = nil
      @controller.with_generation do
        body_up, status, = call_upstream("/v1/chat/completions", body_str)
        result = if status == 200
                   if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(body_up)]]
                   else
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(JSON.parse(body_up)))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :oai)
                 end
      end
      result
    end

    def handle_ant(env)
      body_str    = read_body(env)
      request     = JSON.parse(body_str)
      model_alias = request["model"]
      streaming   = request["stream"] == true

      unless @upstream_fn # legacy test seam injects upstream directly; skip the supervisor
        swap_r = @controller.ensure_active_if_known(model_alias)
        return swap_error_response(swap_r.failure) if swap_r.failure?
      end

      mode       = @controller.active_mode
      normalizer = AntNormalizer.new(
        advertised_model:   effective_model(model_alias),
        supports_reasoning: mode[:supports_reasoning],
      )

      return handle_ant_mlx(body_str, model_alias, normalizer, streaming) if mlx_engine?(model_alias)

      return open_stream("/v1/messages", body_str, normalizer, flavor: :ant) if streaming && @upstream_fn.nil?

      result = nil
      @controller.with_generation do
        body_up, status, = call_upstream("/v1/messages", body_str)
        result = if status == 200
                   if streaming
                     [200, SSE_HEADERS.dup, [normalizer.normalize_stream_to_sse(body_up)]]
                   else
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize(JSON.parse(body_up)))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :ant)
                 end
      end
      result
    end

    def handle_ant_mlx(body_str, model_alias, normalizer, streaming)
      oai_body = ant_to_oai(body_str, mlx_model_id(model_alias),
                            stop_tokens: mlx_stop_tokens(model_alias),)

      if streaming && @upstream_fn.nil?
        return open_stream("/v1/chat/completions", oai_body, OaiToAntAdapter.new(normalizer), flavor: :ant)
      end

      result = nil
      @controller.with_generation do
        body_up, status, = call_upstream("/v1/chat/completions", oai_body)
        result = if status == 200
                   if streaming
                     sse = +""
                     normalizer.stream_to_sse_from_oai(Enumerator.new { |y| y << body_up }) { |s| sse << s }
                     [200, SSE_HEADERS.dup, [sse]]
                   else
                     [200, JSON_HEADERS.dup, [JSON.generate(normalizer.normalize_oai(JSON.parse(body_up)))]]
                   end
                 else
                   @error_relay.relay(status, body_up, flavor: :ant)
                 end
      end
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

    def open_stream(path, body_str, normalizer, flavor:)
      @controller.begin_generation
      succeeded = false
      response, client = @upstream_client.open_stream(path, body_str)
      if response.status == 200
        on_close  = -> { @controller.end_generation }
        succeeded = true
        [200, SSE_HEADERS.dup, StreamBody.new(response, client, normalizer, on_close)]
      else
        @error_relay.relay(response.status, response.read.tap { client.close }, flavor: flavor)
      end
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

    # True when the entry for alias_name (or the default) uses an OAI-upstream
    # engine that the proxy synthesizes ANT from: currently "mlx" and "optiq".
    # Both engines speak OpenAI HTTP; the proxy never forwards /v1/messages to them.
    def mlx_engine?(alias_name)
      entry = @controller.registry.resolve(alias_name) ||
              @controller.registry.resolve(@controller.registry.default_alias)
      %w[mlx optiq].include?(entry&.fetch(:engine, nil))
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

    # Applies OAI-upstream request rewrites for mlx/optiq engines:
    # - mlx only: rewrites the "model" field to the HF repo id (mlx validates
    #   this field against its loaded model; optiq single-model mode accepts any value).
    # - both engines: normalizes "developer" role to "system" and injects stop_tokens.
    def rewrite_model_for_mlx(body_str, model_alias)
      return body_str unless mlx_engine?(model_alias)

      parsed = JSON.parse(body_str)
      entry  = @controller.registry.resolve(model_alias) ||
               @controller.registry.resolve(@controller.registry.default_alias)
      parsed["model"] = mlx_model_id(model_alias) if entry&.fetch(:engine, nil) == "mlx"
      (parsed["messages"] || []).each { |m| m["role"] = "system" if m["role"] == "developer" }
      inject_mlx_stop_tokens(parsed, model_alias)
      JSON.generate(parsed)
    end

    # Minimal ANT→OAI request translation for the mlx/optiq engine path.
    # mlx/optiq speak OAI only; system becomes messages[0]; fields mapped;
    # tool definitions, tool_result, and tool_use blocks are translated to
    # their OAI equivalents (see ant_message_to_oai / ant_tools_to_oai).
    def ant_to_oai(body_str, model_name, stop_tokens: nil)
      ant  = JSON.parse(body_str)
      msgs = []
      msgs << { "role" => "system", "content" => ant["system"] } if ant["system"]
      (ant["messages"] || []).each { |m| ant_message_to_oai(m, msgs) }

      oai = { "model" => model_name, "messages" => msgs }
      oai["tools"]       = ant_tools_to_oai(ant["tools"]) if ant["tools"]
      oai["max_tokens"]  = ant["max_tokens"]  if ant.key?("max_tokens")
      oai["stream"]      = ant["stream"]      if ant.key?("stream")
      oai["temperature"] = ant["temperature"] if ant.key?("temperature")
      oai["top_p"]       = ant["top_p"]       if ant.key?("top_p")
      oai["stop"]        = ant["stop_sequences"] if ant.key?("stop_sequences")
      merge_stop_tokens(oai, stop_tokens) if stop_tokens
      JSON.generate(oai)
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
      %w[mlx optiq].include?(entry&.fetch(:engine, nil)) ? ErrorRelay::Mlx.new : ErrorRelay::Oai.new
    end
  end
end
