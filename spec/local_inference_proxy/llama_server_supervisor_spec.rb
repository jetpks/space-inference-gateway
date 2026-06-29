# frozen_string_literal: true

require "async"
require "socket"

FAKE_BINARY = File.expand_path("../support/fake_llama_server", __dir__)

RSpec.describe LocalInferenceProxy::LlamaServerSupervisor do
  def free_port
    srv = TCPServer.new("127.0.0.1", 0)
    port = srv.addr[1]
    srv.close
    port
  end

  def build_registry(models_hash, default_alias)
    LocalInferenceProxy::ModelRegistry.new(
      "default" => default_alias,
      "models"  => models_hash,
    )
  end

  let(:port)  { free_port }
  let(:port2) { free_port }

  # Health polls returning 503 before the fake server switches to 200.
  # Overridden per-context where needed.
  let(:unready_polls) { 3 }

  let(:registry) do
    build_registry({
                     "test-model" => {
                       "gguf" => "/fake/model.gguf",
                       "port" => port,
                       "ctx" => 0,
                       "parallel" => 1,
                       "binary" => FAKE_BINARY,
                     },
                   }, "test-model",)
  end

  let(:supervisor) do
    LocalInferenceProxy::LlamaServerSupervisor.new(
      registry: registry,
      timeouts:  LocalInferenceProxy::LlamaServerSupervisor::Timeouts.new(readiness: 10, stop_grace: 0.5, poll_interval: 0.05),
      log_dir:   Dir.tmpdir,
    )
  end

  around do |ex|
    ENV["FAKE_UNREADY_POLLS"] = unready_polls.to_s
    ex.run
  ensure
    ENV.delete("FAKE_UNREADY_POLLS")
    # Runs outside any reactor — wrap to make Async::Task.current available.
    Async { supervisor.stop }
  end

  # ── AC5 — ModelRegistry extended for llama.cpp ────────────────────────────

  describe "ModelRegistry (AC5)" do
    it "resolve returns the entry Hash for a known alias" do
      entry = registry.resolve("test-model")
      expect(entry).to be_a(Hash)
      expect(entry[:gguf]).to eq("/fake/model.gguf")
      expect(entry[:port]).to eq(port)
      expect(entry[:binary]).to eq(FAKE_BINARY)
    end

    it "resolve returns nil for an unknown alias" do
      expect(registry.resolve("no-such-model")).to be_nil
    end

    it "preserves aliases and default_alias public API" do
      expect(registry.aliases).to eq(["test-model"])
      expect(registry.default_alias).to eq("test-model")
    end

    it "config/models.yml carries llama.cpp launch fields and has a text-model default" do
      loaded = LocalInferenceProxy::ModelRegistry.load
      expect(loaded.default_alias).to eq("qwen3-27b")
      expect(loaded.aliases).to include("qwen3-27b")
      expect(loaded.aliases).not_to include("diffusiongemma")

      entry = loaded.resolve("qwen3-27b")
      expect(entry).to be_a(Hash)
      expect(entry[:gguf]).to be_a(String)
      expect(entry[:port]).to be_a(Integer)
      expect(entry[:ctx]).to be_a(Integer)
      expect(entry[:parallel]).to be_a(Integer)
    end
  end

  # ── AC2 — Verified argv ────────────────────────────────────────────────────

  describe "#build_argv (AC2)" do
    let(:sample_entry) do
      {
        gguf:     "/models/test.gguf",
        port:     8080,
        ctx:      4096,
        parallel: 2,
        offload:  "fit",
        binary:   "/usr/local/bin/llama-server",
      }
    end

    it "produces the exact verified llama.cpp argv with offload:fit" do
      argv = supervisor.send(:build_argv, sample_entry)
      expect(argv).to eq([
                           "/usr/local/bin/llama-server",
                           "-m", "/models/test.gguf",
                           "--port", "8080",
                           "-c", "4096",
                           "--parallel", "2",
                           "--flash-attn", "on",
                           "--no-context-shift",
                           "--jinja",
                           "--fit", "on",
                         ])
    end

    it "uses -ngl -1 when offload is 'ngl'" do
      argv = supervisor.send(:build_argv, sample_entry.merge(offload: "ngl"))
      expect(argv).to include("-ngl", "-1")
      expect(argv).not_to include("--fit")
    end

    it "omits offload flag when offload is nil" do
      argv = supervisor.send(:build_argv, sample_entry.merge(offload: nil))
      expect(argv).not_to include("--fit")
      expect(argv).not_to include("-ngl")
    end

    it "appends extra_args at the end of argv" do
      argv = supervisor.send(:build_argv, sample_entry.merge(extra_args: ["--threads", "4"]))
      expect(argv.last(2)).to eq(["--threads", "4"])
    end

    it "falls back to constructor binary when entry omits :binary" do
      entry = sample_entry.except(:binary)
      sup   = LocalInferenceProxy::LlamaServerSupervisor.new(
        registry: registry, binary: "/custom/llama-server", log_dir: Dir.tmpdir,
      )
      expect(sup.send(:build_argv, entry).first).to eq("/custom/llama-server")
    end
  end

  # ── AC1 — Spawn + readiness gate ──────────────────────────────────────────

  describe "#start (AC1)" do
    it "returns Failure(:unknown_model) for an unregistered alias" do
      Async do
        result = supervisor.start("no-such-model")
        expect(result).to be_failure
        expect(result.failure).to eq(:unknown_model)
      end
    end

    it "spawns a real child (running? true, pid is a positive integer)" do
      Async do |task|
        task.with_timeout(10) do
          result = supervisor.start("test-model")
          expect(result).to be_success
          expect(supervisor.running?).to be true
          expect(supervisor.pid).to be_a(Integer)
          expect(supervisor.pid).to be > 0
        end
      end
    end

    it "returns base_url and alias in the Success value" do
      Async do |task|
        task.with_timeout(10) do
          result = supervisor.start("test-model")
          expect(result).to be_success
          expect(result.value![:base_url]).to eq("http://127.0.0.1:#{port}")
          expect(result.value![:alias]).to eq("test-model")
          expect(supervisor.base_url).to eq("http://127.0.0.1:#{port}")
          expect(supervisor.active_alias).to eq("test-model")
        end
      end
    end

    context "blocking discriminator — start blocks on readiness, not just spawn" do
      # 20 × 0.05s poll_interval ≥ 1.0s minimum before start returns.
      # Probe at t≈0.3s guarantees start is still blocked.
      let(:unready_polls) { 20 }

      it "probe taken at t≈0.3s sees 503 and start has not returned yet" do
        Async do |task|
          task.with_timeout(15) do
            start_done   = false
            start_result = nil

            task.async do
              start_result = supervisor.start("test-model")
              start_done   = true
            end

            # Give the child time to spawn and bind the port
            task.sleep(0.3)

            expect(start_done).to eq(false), "start must still be blocking on readiness"

            # Direct HTTP probe — fake has served ~6 supervisor polls (all 503);
            # our probe increments health_hits to ~7, still well below 20.
            socket = TCPSocket.new("127.0.0.1", port)
            socket.write("GET /health HTTP/1.0\r\nHost: 127.0.0.1\r\n\r\n")
            socket.flush
            status_line = socket.gets
            socket.close
            expect(status_line.to_s.split[1]).to eq("503")

            # Wait for start to complete now that we've confirmed it was blocking
            loop do
              task.sleep(0.05)
              break if start_done
            end

            expect(start_result).to be_success
            expect(supervisor.running?).to be true
          end
        end
      end
    end

    context "readiness timeout" do
      let(:unready_polls) { 99_999 }

      it "returns Failure(:readiness_timeout) and stops the child" do
        timeout_sup = LocalInferenceProxy::LlamaServerSupervisor.new(
          registry: registry,
          timeouts:  LocalInferenceProxy::LlamaServerSupervisor::Timeouts.new(readiness: 0.5, stop_grace: 0.5, poll_interval: 0.05),
          log_dir:   Dir.tmpdir,
        )

        Async do |task|
          task.with_timeout(8) do
            result = timeout_sup.start("test-model")
            expect(result).to be_failure
            expect(result.failure).to eq(:readiness_timeout)
            expect(timeout_sup.running?).to be false
          end
        end
      end
    end
  end

  # ── AC3 — Clean stop, no orphan ───────────────────────────────────────────

  describe "#stop (AC3)" do
    it "is safe to call when not running" do
      Async do
        expect(supervisor.running?).to be false
        expect { supervisor.stop }.not_to raise_error
      end
    end

    it "terminates the process group; running? false; OS pid gone after stop" do
      Async do |task|
        task.with_timeout(10) do
          supervisor.start("test-model")
          pid = supervisor.pid

          expect(supervisor.running?).to be true

          supervisor.stop

          expect(supervisor.running?).to be false
          expect(supervisor.pid).to be_nil
          expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)
        end
      end
    end

    it "a new start succeeds after stop (port is free)" do
      port_b = free_port
      reg_b  = build_registry({
                                "model-b" => {
                                  "gguf" => "/fake/b.gguf", "port" => port_b,
                                  "ctx" => 0, "parallel" => 1, "binary" => FAKE_BINARY,
                                },
                              }, "model-b",)
      sup_b = LocalInferenceProxy::LlamaServerSupervisor.new(
        registry: reg_b,
        timeouts:  LocalInferenceProxy::LlamaServerSupervisor::Timeouts.new(readiness: 10, stop_grace: 0.5, poll_interval: 0.05),
        log_dir:   Dir.tmpdir,
      )

      Async do |task|
        task.with_timeout(15) do
          supervisor.start("test-model")
          supervisor.stop

          result = sup_b.start("model-b")
          expect(result).to be_success
          sup_b.stop
        end
      end
    end
  end

  # ── AC4 — Serialized atomic swap ──────────────────────────────────────────

  describe "#swap (AC4)" do
    let(:registry) do
      build_registry({
                       "model-a" => {
                         "gguf" => "/fake/a.gguf", "port" => port,
                         "ctx" => 0, "parallel" => 1, "binary" => FAKE_BINARY,
                       },
                       "model-b" => {
                         "gguf" => "/fake/b.gguf", "port" => port2,
          "ctx" => 0, "parallel" => 1, "binary" => FAKE_BINARY,
                       },
                     }, "model-a",)
    end

    it "stops current and starts new; active_alias reflects the swap target" do
      Async do |task|
        task.with_timeout(15) do
          supervisor.start("model-a")
          expect(supervisor.active_alias).to eq("model-a")

          result = supervisor.swap(to: "model-b")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-b")
          expect(supervisor.running?).to be true
        end
      end
    end

    it "two concurrent swaps serialized by semaphore; final alias = last dispatched" do
      Async do |task|
        task.with_timeout(30) do
          supervisor.start("model-a")

          r1 = r2 = nil
          t1 = task.async { r1 = supervisor.swap(to: "model-a") }
          t2 = task.async { r2 = supervisor.swap(to: "model-b") }

          t1.wait
          t2.wait

          expect(r1).to be_success
          expect(r2).to be_success
          # t1 runs first (FIFO), t2 second — t2's target wins
          expect(supervisor.active_alias).to eq("model-b")
          expect(supervisor.running?).to be true
        end
      end
    end

    it "concurrent swaps to same port serialize without port conflict" do
      Async do |task|
        task.with_timeout(30) do
          supervisor.start("model-a")

          r1 = r2 = nil
          t1 = task.async { r1 = supervisor.swap(to: "model-a") }
          t2 = task.async { r2 = supervisor.swap(to: "model-a") }

          t1.wait
          t2.wait

          expect(r1).to be_success
          expect(r2).to be_success
          expect(supervisor.active_alias).to eq("model-a")
          expect(supervisor.running?).to be true
        end
      end
    end

    it "swap from idle starts the target without requiring a prior start" do
      Async do |task|
        task.with_timeout(10) do
          expect(supervisor.running?).to be false
          result = supervisor.swap(to: "model-a")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-a")
        end
      end
    end

    it "swap to unknown alias returns Failure(:unknown_model)" do
      Async do |task|
        task.with_timeout(10) do
          supervisor.start("model-a")
          result = supervisor.swap(to: "no-such-model")
          expect(result).to be_failure
          expect(result.failure).to eq(:unknown_model)
        end
      end
    end
  end
end
