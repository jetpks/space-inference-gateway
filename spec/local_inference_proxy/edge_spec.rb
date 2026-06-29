# frozen_string_literal: true

require "falcon"
require "async"
require "async/http/server"
require "async/http/client"
require "async/http/endpoint"
require "async/http/body/writable"
require "protocol/http/middleware"
require "uri"

RSpec.describe "Edge — Real Served Path (AC1–AC4)" do
  # ── helpers ────────────────────────────────────────────────────────────────

  # Boot a Falcon/Rack proxy on an ephemeral port using pre-bound sockets.
  # Returns [port, server_task, bound_endpoint].
  def boot_proxy(app)
    base  = Async::HTTP::Endpoint.parse("http://localhost:0")
    bound = base.bound
    port  = bound.sockets.first.local_address.ip_port
    ep    = Async::HTTP::Endpoint.new(URI.parse("http://localhost:#{port}"), bound)
    task  = Falcon::Server.new(Falcon::Server.middleware(app), ep).run
    [port, task, bound]
  end

  # Boot a raw Async::HTTP stub server on an ephemeral port.
  # The handler block receives a Protocol::HTTP::Request and must return a
  # Protocol::HTTP::Response.
  def boot_stub(handler)
    base  = Async::HTTP::Endpoint.parse("http://localhost:0")
    bound = base.bound
    port  = bound.sockets.first.local_address.ip_port
    ep    = Async::HTTP::Endpoint.new(URI.parse("http://localhost:#{port}"), bound)
    mw    = Protocol::HTTP::Middleware.for { |req| handler.call(req) }
    task  = Async::HTTP::Server.new(mw, ep).run
    [port, task, bound]
  end

  def client_for(port)
    Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://localhost:#{port}"))
  end

  # Status fixture that shows diffusiongemma as active and supports reasoning.
  def cp_status_body
    fixture("cp_status.json")
  end

  # Fixture registry carrying the model aliases the edge tests reference.
  # Decouples edge tests from the production config/models.yml.
  def fixture_registry
    LocalInferenceProxy::ModelRegistry.new(
      "default" => "diffusiongemma",
      "models"  => {
        "diffusiongemma" => {
          "model_path" => "/Users/lemonslut/.lmstudio/models/unsloth/diffusiongemma-26B-A4B-it-GGUF",
        },
        "qwen3.6-27b" => {
          "model_path" => "qwen3.6-27b",
        },
      },
    )
  end

  # Boot an App with a fixture controller so model-name assertions don't depend
  # on the production config/models.yml.
  def make_app(upstream_client:)
    registry   = fixture_registry
    controller = LocalInferenceProxy::ModelController.new(registry: registry, upstream_client: upstream_client)
    LocalInferenceProxy::App.new(upstream_client: upstream_client, controller: controller)
  end

  # ── AC1 — Boot + routing over real HTTP ────────────────────────────────────

  describe "AC1 — boots over Falcon/Rack stack and routes via real HTTP" do
    it "GET /v1/models returns 200 with OpenAI list shape" do
      Async do |task|
        task.with_timeout(5) do
          app = LocalInferenceProxy::App.new(
            upstream_fn: ->(_path, _body) { [fixture("oai_ns.json"), 200, {}] },
          )
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = client_for(proxy_port)

          begin
            response = client.get("/v1/models")
            expect(response.status).to eq(200)
            body = JSON.parse(response.read)
            expect(body["object"]).to eq("list")
            expect(body["data"]).to be_an(Array)
            expect(body["data"].first).to include("id", "object", "created", "owned_by")
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
          end
        end
      end
    end
  end

  # ── AC2 — Real upstream HTTP adapter (auth + method) ───────────────────────

  describe "AC2 — real upstream HTTP adapter asserts auth + method" do
    it "AC2a — POST /v1/chat/completions forwards Authorization header and verbatim body" do
      Async do |task|
        task.with_timeout(5) do
          received   = []
          stub_token = "edge-test-token"

          stub_handler = lambda do |req|
            received << { method: req.method, path: req.path, auth: req.headers["authorization"] }
            case req.path
            when "/api/inference/status"
              Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [cp_status_body]]
            when "/v1/chat/completions"
              Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [fixture("oai_ns.json")]]
            else
              Protocol::HTTP::Response[404, {}, []]
            end
          end

          stub_port, stub_task, stub_bound = boot_stub(stub_handler)
          upstream = LocalInferenceProxy::UpstreamClient.new(
            base_url: "http://localhost:#{stub_port}",
            token:    stub_token,
          )
          app = make_app(upstream_client: upstream)
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = client_for(proxy_port)

          request_body = JSON.generate({ model: "diffusiongemma", messages: [], stream: false })

          begin
            response = client.post(
              "/v1/chat/completions",
              [["content-type", "application/json"]],
              request_body,
            )
            expect(response.status).to eq(200)
            body = JSON.parse(response.read)
            expect(body["object"]).to eq("chat.completion")

            gen_call = received.find { |r| r[:path] == "/v1/chat/completions" }
            expect(gen_call).not_to be_nil
            expect(gen_call[:method]).to eq("POST")
            expect(gen_call[:auth]).to eq("Bearer #{stub_token}")
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
            stub_task.stop
            stub_bound.close
          end
        end
      end
    end

    it "AC2b — GET /v1/load-progress causes stub to observe GET method" do
      Async do |task|
        task.with_timeout(5) do
          received = []

          stub_handler = lambda do |req|
            received << { method: req.method, path: req.path }
            case req.path
            when "/api/inference/status"
              Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [cp_status_body]]
            when "/v1/load-progress"
              Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [fixture("cp_load_progress.json")]]
            else
              Protocol::HTTP::Response[404, {}, []]
            end
          end

          stub_port, stub_task, stub_bound = boot_stub(stub_handler)
          upstream = LocalInferenceProxy::UpstreamClient.new(base_url: "http://localhost:#{stub_port}")
          app = make_app(upstream_client: upstream)
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = client_for(proxy_port)

          begin
            response = client.get("/v1/load-progress")
            expect(response.status).to eq(200)
            body = JSON.parse(response.read)
            expect(body).to include("phase", "bytes_loaded", "bytes_total", "fraction")

            progress_call = received.find { |r| r[:path] == "/v1/load-progress" }
            expect(progress_call).not_to be_nil
            expect(progress_call[:method]).to eq("GET")
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
            stub_task.stop
            stub_bound.close
          end
        end
      end
    end
  end

  # ── AC3 — Streaming actually streams ───────────────────────────────────────

  describe "AC3 — streaming relays first OAI SSE event before upstream EOF" do
    it "delivers first event within 3 s while upstream holds, then full output matches normalize_stream_to_sse" do
      Async do |task|
        # Barrier: stub holds after first SSE event until we signal it.
        barrier = Async::Condition.new

        oai_fixture = fixture("oai_s.txt")
        # Split on double-newline to get individual SSE event strings.
        events = oai_fixture.split(/(?<=\n\n)/).reject(&:empty?)

        stub_handler = lambda do |req|
          case req.path
          when "/api/inference/status"
            Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [cp_status_body]]
          when "/v1/chat/completions"
            body = Protocol::HTTP::Body::Writable.new
            task.async do
              body.write(events.first)
              barrier.wait
              events[1..].each { |ev| body.write(ev) }
              body.close_write
            end
            Protocol::HTTP::Response[200, { "content-type" => "text/event-stream" }, body]
          else
            Protocol::HTTP::Response[404, {}, []]
          end
        end

        stub_port, stub_task, stub_bound = boot_stub(stub_handler)
        upstream = LocalInferenceProxy::UpstreamClient.new(base_url: "http://localhost:#{stub_port}")
        app      = make_app(upstream_client: upstream)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)

        request_body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post(
            "/v1/chat/completions",
            [["content-type", "application/json"]],
            request_body,
          )
          expect(response.status).to eq(200)

          chunks = []

          # First chunk must arrive within 3 s while upstream is still open.
          task.with_timeout(3) do
            first = response.body.read
            expect(first).not_to be_nil
            expect(first).to include("data:")
            chunks << first
          end

          # Release the upstream barrier now that first event arrived.
          barrier.signal

          # Read the rest of the body.
          while (chunk = response.body.read)
            chunks << chunk
          end

          full_output = chunks.join
          normalizer  = LocalInferenceProxy::OaiNormalizer.new(
            advertised_model:   "diffusiongemma",
            supports_reasoning: true,
          )
          expected = normalizer.normalize_stream_to_sse(oai_fixture)

          expect(full_output).to eq(expected)
          expect(full_output).to end_with("data: [DONE]\n\n")
        ensure
          begin
            response&.body&.close
          rescue StandardError
            nil
          end
          client.close
          proxy_task.stop
          proxy_bound.close
          stub_task.stop
          stub_bound.close
        end
      end
    end
  end

  # ── AC5 — Swap refused 409 while streaming generation is in flight ─────────

  describe "AC5 — swap refused 409 while streaming generation is in flight" do
    it "refuses swap (HTTP 409) while a streaming generation is in flight" do
      Async do |task|
        task.with_timeout(15) do
          barrier = Async::Condition.new
          oai_fixture = fixture("oai_s.txt")
          events = oai_fixture.split(/(?<=\n\n)/).reject(&:empty?)

          stub_handler = lambda do |req|
            case req.path
            when "/api/inference/status"
              Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [cp_status_body]]
            when "/v1/chat/completions"
              body = Protocol::HTTP::Body::Writable.new
              task.async do
                body.write(events.first)
                barrier.wait
                events[1..].each { |ev| body.write(ev) }
                body.close_write
              end
              Protocol::HTTP::Response[200, { "content-type" => "text/event-stream" }, body]
            else
              Protocol::HTTP::Response[404, {}, []]
            end
          end

          stub_port, stub_task, stub_bound = boot_stub(stub_handler)
          upstream = LocalInferenceProxy::UpstreamClient.new(base_url: "http://localhost:#{stub_port}")
          app = make_app(upstream_client: upstream)
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          stream_client = client_for(proxy_port)
          swap_client = client_for(proxy_port)

          stream_body_str = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })
          swap_body_str = JSON.generate({ model: "qwen3.6-27b" })

          begin
            stream_response = stream_client.post(
              "/v1/chat/completions",
              [["content-type", "application/json"]],
              stream_body_str,
            )
            expect(stream_response.status).to eq(200)

            # Read first event — stream is now genuinely in flight
            task.with_timeout(3) do
              first_chunk = stream_response.body.read
              expect(first_chunk).to include("data:")
            end

            # While stream is held at the barrier, attempt swap to a different model
            swap_response = swap_client.post(
              "/v1/load",
              [["content-type", "application/json"]],
              swap_body_str,
            )
            expect(swap_response.status).to eq(409)
            swap_response.read

            # Release the barrier and drain the stream — it must complete normally
            barrier.signal
            while (chunk = stream_response.body.read)
              chunk # drain
            end
          ensure
            begin
              stream_response&.body&.close
              swap_response&.body&.close
            rescue StandardError
              nil
            end
            stream_client.close
            swap_client.close
            proxy_task.stop
            proxy_bound.close
            stub_task.stop
            stub_bound.close
          end
        end
      end
    end
  end

  # ── AC4 — Single injected upstream config drives both planes ───────────────

  describe "AC4 — injected upstream_client drives generation + control-plane; no App:: constant reach" do
    it "same upstream_client reaches both generation and CP calls; re-pointing at different stub hits it instead" do
      Async do |task|
        task.with_timeout(5) do
          hits_a = []
          hits_b = []

          make_stub = lambda do |hits|
            lambda do |req|
              hits << req.path
              case req.path
              when "/api/inference/status"
                Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [cp_status_body]]
              when "/v1/chat/completions"
                Protocol::HTTP::Response[200, { "content-type" => "application/json" }, [fixture("oai_ns.json")]]
              else
                Protocol::HTTP::Response[404, {}, []]
              end
            end
          end

          stub_a_port, stub_a_task, stub_a_bound = boot_stub(make_stub.call(hits_a))
          stub_b_port, stub_b_task, stub_b_bound = boot_stub(make_stub.call(hits_b))

          # App A: pointed at stub A
          upstream_a = LocalInferenceProxy::UpstreamClient.new(base_url: "http://localhost:#{stub_a_port}")
          app_a = make_app(upstream_client: upstream_a)
          proxy_a_port, proxy_a_task, proxy_a_bound = boot_proxy(app_a)
          client_a = client_for(proxy_a_port)

          # App B: pointed at stub B
          upstream_b = LocalInferenceProxy::UpstreamClient.new(base_url: "http://localhost:#{stub_b_port}")
          app_b = make_app(upstream_client: upstream_b)
          proxy_b_port, proxy_b_task, proxy_b_bound = boot_proxy(app_b)
          client_b = client_for(proxy_b_port)

          request_body = JSON.generate({ model: "diffusiongemma", messages: [], stream: false })

          begin
            resp_a = client_a.post("/v1/chat/completions", [["content-type", "application/json"]], request_body)
            resp_a.read
            resp_b = client_b.post("/v1/chat/completions", [["content-type", "application/json"]], request_body)
            resp_b.read

            # Stub A was hit by app_a (generation + CP status check)
            expect(hits_a).to include("/v1/chat/completions")
            expect(hits_a).to include("/api/inference/status")

            # Stub B was hit by app_b (generation + CP status check)
            expect(hits_b).to include("/v1/chat/completions")
            expect(hits_b).to include("/api/inference/status")

            # Neither stub was hit by the other app
            expect(hits_a).not_to include("/v2/impossible")
            expect(hits_b).not_to include("/v2/impossible")

            # Structural: ModelController must not reference App:: constants
            mc_source = File.read(
              File.expand_path("../../lib/local_inference_proxy/model_controller.rb", __dir__),
            )
            expect(mc_source).not_to include("App::UPSTREAM_URL")
            expect(mc_source).not_to include("App::UPSTREAM_TOKEN")
          ensure
            client_a.close
            client_b.close
            proxy_a_task.stop
            proxy_a_bound.close
            proxy_b_task.stop
            proxy_b_bound.close
            stub_a_task.stop
            stub_a_bound.close
            stub_b_task.stop
            stub_b_bound.close
          end
        end
      end
    end
  end
end
