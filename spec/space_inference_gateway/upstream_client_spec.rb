# frozen_string_literal: true

require_relative "../support/fake_upstream_server"

# UpstreamClient timeout split (I05 AC4): the buffered (#call) path and the
# streaming path used to share UPSTREAM_IDLE_TIMEOUT — the buffered path is
# driven here against a real in-process raw-socket fake upstream (no
# mock/stub of UpstreamClient) to prove it is independently configured.
# I06: the streaming leg moved to RawCompletionsStreamer (its idle-gap re-arm
# coverage lives in raw_completions_streamer_spec + stream_lifecycle_spec);
# UpstreamClient keeps #call — the control plane and buffered non-stream path.
RSpec.describe SpaceInferenceGateway::UpstreamClient do
  include FakeUpstreamServer

  around do |example|
    Async do |task|
      @task = task
      example.run
    end
  end

  describe "timeout constants (AC4)" do
    it "UPSTREAM_IDLE_TIMEOUT defaults to 1400 (env-overridable via UPSTREAM_IDLE_TIMEOUT)" do
      expect(ENV.fetch("UPSTREAM_IDLE_TIMEOUT", nil)).to be_nil
      expect(described_class::UPSTREAM_IDLE_TIMEOUT).to eq(1400)
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
end
