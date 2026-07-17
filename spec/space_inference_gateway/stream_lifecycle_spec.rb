# frozen_string_literal: true

require_relative "../support/fake_upstream_server"

# Streaming-lifecycle specs (I02): drives the public Rack surface against a
# real in-process Async::HTTP proxy stack and a hand-scripted raw-socket fake
# upstream — no mock/stub of App, UpstreamClient, or ModelController. Every
# stall scenario runs with a short UPSTREAM_IDLE_TIMEOUT so the suite stays fast.
RSpec.describe "Stream lifecycle (I02 AC2-AC7, AC9)" do
  include FakeUpstreamServer

  around do |example|
    Async do |task|
      @task = task
      example.run
    end
  end

  # ── I04 AC2 — env knob default ──────────────────────────────────────────────

  describe "UpstreamClient::UPSTREAM_HEADERS_TIMEOUT" do
    it "defaults to 300 (env-overridable via UPSTREAM_HEADERS_TIMEOUT)" do
      expect(ENV.fetch("UPSTREAM_HEADERS_TIMEOUT", nil)).to be_nil
      expect(SpaceInferenceGateway::UpstreamClient::UPSTREAM_HEADERS_TIMEOUT).to eq(300)
    end
  end

  # ── AC4 — buffered (non-stream) idle-gap timeout ────────────────────────────

  describe "AC4 — buffered path idle-gap timeout" do
    it "never-responding upstream yields 504 in OAI flavor within the configured budget" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept { |_sock| @task.sleep(60) } # never responds

        client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 1)

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        body, status, = client.call("POST", "/v1/chat/completions", "{}")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(status).to eq(504)
        expect(body).to include("timeout")
        expect(elapsed).to be < 3
      ensure
        upstream.stop
      end
    end

    it "mid-stream-stalling upstream (headers sent, body never arrives) yields 504 within budget" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
          @task.sleep(60) # headers arrive, body never does
        end

        client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 1)

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _body, status, = client.call("POST", "/v1/chat/completions", "{}")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(status).to eq(504)
        expect(elapsed).to be < 3
      ensure
        upstream.stop
      end
    end

    it "a continuously-emitting body never times out, despite exceeding the idle timeout in total" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n")
          3.times do
            @task.sleep(0.4) # < 1s idle timeout, but 3 * 0.4s = 1.2s > 1s total
            http_chunk(sock, "x")
          end
          end_chunks(sock)
        end

        client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 1)
        body, status, = client.call("POST", "/v1/chat/completions", "{}")

        expect(status).to eq(200)
        expect(body).to eq("xxx")
      ensure
        upstream.stop
      end
    end
  end

  # ── AC4 — streaming (open_stream) header-wait idle-gap timeout ─────────────

  describe "AC4 — streaming path header-wait idle-gap timeout" do
    it "never-responding upstream on a streaming request yields 504 in OAI flavor, full teardown" do
      @task.with_timeout(5) do
        SpaceInferenceGateway::Metrics.reset_all
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept { |_sock| @task.sleep(60) } # never responds

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 1)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)

        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          response_body = response.read
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

          expect(response.status).to eq(504)
          expect(response.headers["content-type"]).to include("application/json")
          expect(JSON.parse(response_body).dig("error", "message")).to be_a(String)
          expect(elapsed).to be < 3

          # AC5 — counter released, swap unbrickable.
          expect(SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get).to eq(0)
          swap = app.instance_variable_get(:@controller).ensure_active("qwen3.6-27b")
          expect(swap.success?).to be true

          # AC7 — timeout observable, distinguishable by status label.
          expect(
            SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(labels: { status: "504", flavor: "oai" }),
          ).to eq(1)
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end
  end

  # ── I04 AC2 — headers/idle split ────────────────────────────────────────────

  describe "I04 AC2 — streaming headers-wait bound is distinct from the idle-gap bound" do
    it "never-responding upstream 504s within the (short) headers timeout, well under a long idle timeout" do
      @task.with_timeout(5) do
        SpaceInferenceGateway::Metrics.reset_all
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept { |_sock| @task.sleep(60) } # never responds

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(
          base_url: upstream.base_url, idle_timeout: 30, headers_timeout: 1,
        )
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)

        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          response_body = response.read
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

          expect(response.status).to eq(504)
          expect(JSON.parse(response_body).dig("error", "message")).to be_a(String)
          expect(elapsed).to be < 3 # bounded by headers_timeout (1s), not idle_timeout (30s)

          expect(
            SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(labels: { status: "504", flavor: "oai" }),
          ).to eq(1)
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end

    it "headers + one chunk then stall: stream ends only after the (long) idle gap, not the headers bound" do
      @task.with_timeout(8) do
        SpaceInferenceGateway::Metrics.reset_all
        first_event = fixture("oai_s.txt").split(/(?<=\n\n)/).reject(&:empty?).first

        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, first_event)
          @task.sleep(60) # headers + one chunk arrive, then stall
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(
          base_url: upstream.base_url, idle_timeout: 1, headers_timeout: 30,
        )
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)

        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(200) # headers arrived promptly, well under headers_timeout

          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          first = response.body.read
          expect(first).to include("data:")

          nil while response.body.read # drain until EOF (drain fiber ends the pipe on IO::TimeoutError)
          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

          expect(elapsed).to be >= 1 # ended after the idle gap, not cut short by headers_timeout

          @task.with_timeout(3) do
            @task.sleep(0.05) until SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(
              labels: { status: "504", flavor: "oai" },
            ) == 1
          end
          expect(
            SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(labels: { status: "504", flavor: "oai" }),
          ).to eq(1)
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end
  end

  # ── AC2 + AC3 + AC5 — downstream abandon while upstream streams then stalls ─

  describe "AC2/AC3/AC5 — downstream abandon cancels a stalled upstream" do
    it "closes upstream, terminates the drain fiber, releases the counter, no pool-drain hang" do
      stub_const("SpaceInferenceGateway::App::KEEPALIVE_INTERVAL", 1)

      @task.with_timeout(10) do
        SpaceInferenceGateway::Metrics.reset_all
        first_event = fixture("oai_s.txt").split(/(?<=\n\n)/).reject(&:empty?).first
        upstream_sock = nil

        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          upstream_sock = sock
          sse_headers(sock)
          http_chunk(sock, first_event)
          # stall — no more chunks, no close; only a downstream abandon should end this
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 30)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        stream_client = client_for(proxy_port)

        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          stream_response = stream_client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(stream_response.status).to eq(200)

          first = stream_response.body.read
          expect(first).to include("data:")
          expect(SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get).to eq(1)

          # Simulate the downstream client vanishing mid-stream (kill -9 / dropped
          # connection): tear down the response then the client, same order proven
          # safe in the PHASE-0 probes.
          stream_response.close
          stream_client.close

          # No new disconnect-detection machinery: the frozen keepalive write
          # (shortened here for test speed) is what discovers the dead socket.
          expect(upstream.observe_close(upstream_sock, timeout: 5)).to be true

          # AC5 — counter released promptly (would stay 1 forever under the old bug).
          # response.close alone is enough for the upstream to observe EOF, slightly
          # ahead of client.close + the on_close counter decrement later in the same
          # teardown — so poll with a bounded wait rather than asserting instantaneously.
          @task.with_timeout(3) do
            @task.sleep(0.05) until SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get.zero?
          end
          expect(SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get).to eq(0)
          swap = app.instance_variable_get(:@controller).ensure_active("qwen3.6-27b")
          expect(swap.success?).to be true
        ensure
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end
  end

  # ── AC5 — upstream non-200 / open-stream failure ────────────────────────────

  describe "AC5 — counter lifecycle on upstream non-200 and open-stream failure" do
    it "upstream non-200 on stream open releases the counter" do
      @task.with_timeout(5) do
        SpaceInferenceGateway::Metrics.reset_all
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          error_body = JSON.generate({ error: { message: "bad request", type: "invalid_request_error" } })
          sock.write(
            "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{error_body.bytesize}\r\n\r\n#{error_body}",
          )
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 5)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)
        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(400)
          response.read

          expect(SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get).to eq(0)
          swap = app.instance_variable_get(:@controller).ensure_active("qwen3.6-27b")
          expect(swap.success?).to be true
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end

    it "open-stream connection failure (refused) releases the counter" do
      @task.with_timeout(5) do
        SpaceInferenceGateway::Metrics.reset_all
        dead_server = TCPServer.new("127.0.0.1", 0)
        dead_port   = dead_server.local_address.ip_port
        dead_server.close # port now refuses connections

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(
          base_url: "http://127.0.0.1:#{dead_port}", idle_timeout: 5,
        )
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)
        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(502)
          response.read

          expect(SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get).to eq(0)
          swap = app.instance_variable_get(:@controller).ensure_active("qwen3.6-27b")
          expect(swap.success?).to be true
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
        end
      end
    end
  end

  # ── AC6 — streaming duration measured at close, not at open ────────────────

  describe "AC6 — streaming duration observed at teardown" do
    it "sig_request_duration_seconds{stream=true} reflects the held-open duration" do
      @task.with_timeout(6) do
        SpaceInferenceGateway::Metrics.reset_all
        first_event = fixture("oai_s.txt").split(/(?<=\n\n)/).reject(&:empty?).first

        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, first_event)
          @task.sleep(0.6) # held open — the whole point of this test
          end_chunks(sock)
        end

        upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 5)
        app = make_app(upstream_client: upstream_client)
        proxy_port, proxy_task, proxy_bound = boot_proxy(app)
        client = client_for(proxy_port)
        body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

        begin
          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(200)

          # sig_requests_total counts at accept, before any duration has elapsed.
          expect(
            SpaceInferenceGateway::Metrics::REQUESTS.get(labels: { flavor: "oai", stream: "true" }),
          ).to eq(1)

          nil while response.body.read # drain to natural completion (closes the body)

          # Server-side teardown (StreamBody#close, which observes duration before
          # decrementing the counter) runs in Falcon's own task, not this fiber — wait
          # for it rather than assuming it finished the instant the client saw EOF.
          @task.with_timeout(3) do
            @task.sleep(0.05) until SpaceInferenceGateway::Metrics::ACTIVE_GENERATIONS.get.zero?
          end

          observed_sum = SpaceInferenceGateway::Metrics::REQUEST_DURATION.get(
            labels: { flavor: "oai", stream: "true" },
          )["sum"]
          expect(observed_sum).to be >= 0.5
        ensure
          client.close
          proxy_task.stop
          proxy_bound.close
          upstream.stop
        end
      end
    end
  end
end
