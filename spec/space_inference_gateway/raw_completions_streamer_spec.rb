# frozen_string_literal: true

require_relative "../support/fake_upstream_server"

# RawCompletionsStreamer (I06, BRIEF §3) — the streaming completions leg's
# transport on the fast-completions raw surface. Driven against a real
# in-process raw-socket fake upstream (no mock/stub): the authorization
# header discipline, the open-gate error mapping, the always-terminal DONE,
# and the mid-stream inactivity timeout observable as a silent pipe EOF plus
# a 504 in sig_upstream_errors. The public Rack-surface behaviors (504 relay,
# teardown, abandon, duration) live in stream_lifecycle_spec; the per-chunk
# inactivity re-arm proof lives there too (AC4).
RSpec.describe SpaceInferenceGateway::RawCompletionsStreamer do
  include FakeUpstreamServer

  around do |example|
    run_in_reactor(example)
  end

  let(:normalizer) do
    SpaceInferenceGateway::OaiNormalizer.new(advertised_model: "diffusiongemma", supports_reasoning: true)
  end

  # Drain the session pipe the way StreamBody#each does (wait_readable +
  # read_nonblock — fiber-scheduler-safe), under a hard overall budget so a
  # silent upstream fails loudly instead of hanging the suite.
  def drain_session(session, budget: 5)
    output   = +""
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + budget
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      raise "session drain exceeded #{budget}s budget without EOF" if remaining <= 0

      next if session.read_io.wait_readable(remaining).nil?

      chunk = session.read_io.read_nonblock(65_536, exception: false)
      break if chunk.nil? # EOF — upstream finished

      next if chunk == :wait_readable # spurious wakeup

      output << chunk unless chunk.empty?
    end
    output
  end

  describe "authorization header discipline (raw-surface api_key semantics)" do
    it "omits the authorization header when the token is empty (default)" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, "data: {}\n\n")
          end_chunks(sock)
        end

        streamer = described_class.new(base_url: upstream.base_url)
        session  = streamer.open("{}", normalizer: normalizer)
        drain_session(session)

        expect(upstream.last_head).to be_a(String)
        expect(upstream.last_head).to match(%r{^POST /v1/chat/completions })
        expect(upstream.last_head).not_to match(/^authorization:/i)
      ensure
        session&.close
        upstream.stop
      end
    end

    it "sends `authorization: Bearer <token>` when a token is configured" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, "data: {}\n\n")
          end_chunks(sock)
        end

        streamer = described_class.new(base_url: upstream.base_url, token: "sekrit")
        session  = streamer.open("{}", normalizer: normalizer)
        drain_session(session)

        expect(upstream.last_head).to match(/^authorization: Bearer sekrit\r?$/i)
      ensure
        session&.close
        upstream.stop
      end
    end
  end

  describe "open-gate error mapping" do
    it "raises Fast::Completions::ApiError carrying the upstream status and body on a non-2xx" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          error_body = JSON.generate({ error: "model is overloaded" })
          sock.write(
            "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n" \
            "Content-Length: #{error_body.bytesize}\r\n\r\n#{error_body}",
          )
        end

        streamer = described_class.new(base_url: upstream.base_url, idle_timeout: 5)
        expect { streamer.open("{}", normalizer: normalizer) }
          .to raise_error(Fast::Completions::ServerError) do |e|
            expect(e.status).to eq(503)
            expect(e.body).to include("model is overloaded")
          end
      ensure
        upstream.stop
      end
    end
  end

  describe "terminal DONE" do
    it "an event-free 2xx body still yields the terminal data: [DONE]" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          end_chunks(sock) # 200 with an empty body — no events at all
        end

        streamer = described_class.new(base_url: upstream.base_url)
        session  = streamer.open("{}", normalizer: normalizer)

        expect(drain_session(session)).to eq("data: [DONE]\n\n")
      ensure
        session&.close
        upstream.stop
      end
    end
  end

  describe "mid-stream inactivity timeout" do
    it "ends the session silently (pipe EOF) and counts a 504 in sig_upstream_errors" do
      @task.with_timeout(8) do
        SpaceInferenceGateway::Metrics.reset_all
        first_event = fixture("oai_s.txt").split(/(?<=\n\n)/).reject(&:empty?).first

        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, first_event)
          @task.sleep(60) # headers + one chunk arrive, then stall
        end

        streamer = described_class.new(base_url: upstream.base_url, idle_timeout: 0.2, headers_timeout: 30)
        session  = streamer.open("{}", normalizer: normalizer)

        output = drain_session(session, budget: 5)
        expect(output).to include("data:")

        # The EOF came from the inactivity watchdog, not the upstream: the
        # 504 is counted even though the SSE stream can only end silently.
        @task.with_timeout(3) do
          @task.sleep(0.05) until SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(
            labels: { status: "504" },
          ) == 1
        end
        expect(SpaceInferenceGateway::Metrics::UPSTREAM_ERRORS.get(labels: { status: "504" })).to eq(1)
      ensure
        session&.close
        upstream.stop
      end
    end
  end
end
