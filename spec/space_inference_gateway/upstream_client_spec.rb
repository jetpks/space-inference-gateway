# frozen_string_literal: true

require_relative "../support/fake_upstream_server"

# UpstreamClient timeout split (I05 AC4): the buffered (#call) path and the
# streaming (#open_stream) path used to share UPSTREAM_IDLE_TIMEOUT — this
# drives both against a real in-process raw-socket fake upstream (no
# mock/stub of UpstreamClient) to prove they're independently configured.
RSpec.describe SpaceInferenceGateway::UpstreamClient do
  include FakeUpstreamServer

  around do |example|
    Async do |task|
      @task = task
      example.run
    end
  end

  describe "timeout constants (AC4)" do
    it "UPSTREAM_IDLE_TIMEOUT defaults to 600 (env-overridable via UPSTREAM_IDLE_TIMEOUT)" do
      expect(ENV.fetch("UPSTREAM_IDLE_TIMEOUT", nil)).to be_nil
      expect(described_class::UPSTREAM_IDLE_TIMEOUT).to eq(600)
    end

    it "UPSTREAM_BUFFERED_TIMEOUT defaults to 1800 (env-overridable via UPSTREAM_BUFFERED_TIMEOUT)" do
      expect(ENV.fetch("UPSTREAM_BUFFERED_TIMEOUT", nil)).to be_nil
      expect(described_class::UPSTREAM_BUFFERED_TIMEOUT).to eq(1800)
    end

    it "the two constants are independent values" do
      expect(described_class::UPSTREAM_BUFFERED_TIMEOUT).not_to eq(described_class::UPSTREAM_IDLE_TIMEOUT)
    end
  end

  describe "#call uses the buffered timeout, not the idle-gap one" do
    it "times out on a short buffered_timeout despite a long idle_timeout" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept { |_sock| @task.sleep(60) } # never responds

        client = described_class.new(base_url: upstream.base_url, idle_timeout: 30, buffered_timeout: 0.3)

        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        _body, status, = client.call("POST", "/v1/chat/completions", "{}")
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        expect(status).to eq(504)
        expect(elapsed).to be < 2
      ensure
        upstream.stop
      end
    end

    it "does not time out within a long buffered_timeout despite a short idle_timeout" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          body = fixture("oai_ns.json")
          sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        end

        client = described_class.new(base_url: upstream.base_url, idle_timeout: 0.1, buffered_timeout: 30)

        _body, status, = client.call("POST", "/v1/chat/completions", "{}")

        expect(status).to eq(200)
      ensure
        upstream.stop
      end
    end
  end

  describe "#open_stream uses the idle-gap timeout, not the buffered one" do
    it "times out mid-stream on a short idle_timeout despite a long buffered_timeout" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, "data: {}\n\n")
          @task.sleep(60) # headers + one chunk arrive, then stall
        end

        client = described_class.new(base_url: upstream.base_url, idle_timeout: 0.3, buffered_timeout: 1800)
        response, http_client = client.open_stream("/v1/chat/completions", "{}")

        expect(response.status).to eq(200)
        expect { @task.with_timeout(2) { response.read } }.to raise_error(IO::TimeoutError)
      ensure
        http_client&.close
        upstream.stop
      end
    end

    it "does not time out within a long idle_timeout despite a short buffered_timeout" do
      @task.with_timeout(5) do
        upstream = FakeUpstreamServer::RawUpstream.new(@task)
        upstream.accept do |sock|
          sse_headers(sock)
          http_chunk(sock, "data: {}\n\n")
          end_chunks(sock)
        end

        client = described_class.new(base_url: upstream.base_url, idle_timeout: 30, buffered_timeout: 0.1)
        response, http_client = client.open_stream("/v1/chat/completions", "{}")

        expect(response.status).to eq(200)
        expect(response.read).to include("data: {}")
      ensure
        http_client&.close
        upstream.stop
      end
    end
  end
end
