# frozen_string_literal: true

require "async"
require "socket"

FAKE_INF_BINARY = File.expand_path("../support/fake_llama_server", __dir__)

RSpec.describe SpaceInferenceGateway::InferenceServerSupervisor do
  def free_port
    srv  = TCPServer.new("127.0.0.1", 0)
    port = srv.addr[1]
    srv.close
    port
  end

  def build_registry(models_hash, default_alias)
    SpaceInferenceGateway::ModelRegistry.new(
      "default" => default_alias,
      "models"  => models_hash,
    )
  end

  let(:port)  { free_port }
  let(:port2) { free_port }
  let(:unready_polls) { 3 }

  let(:registry) do
    build_registry(
      {
        "test-model" => {
          "engine" => "mlx",
          "venv" => FAKE_INF_BINARY,
          "model_dir" => "/fake/model",
          "port" => port,
        },
      },
      "test-model",
    )
  end

  let(:supervisor) do
    SpaceInferenceGateway::InferenceServerSupervisor.new(
      registry: registry,
      timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
        readiness: 10, stop_grace: 0.5, poll_interval: 0.05,
      ),
      log_dir: Dir.tmpdir,
    )
  end

  around do |ex|
    ENV["FAKE_UNREADY_POLLS"] = unready_polls.to_s
    ex.run
  ensure
    ENV.delete("FAKE_UNREADY_POLLS")
    Async { supervisor.stop }
  end

  # ── AC2 — exact mlx argv ───────────────────────────────────────────────────

  describe "#build_argv (AC2)" do
    let(:entry) do
      {
        venv:               "/home/user/.venv/bin/python",
        model_dir:          "/models/Qwen3.5-35B-A3B-4bit",
        port:               8080,
        decode_concurrency: 32,
        prompt_concurrency: 8,
      }
    end

    it "builds exact mlx_lm.server argv" do
      expect(supervisor.send(:build_argv, entry)).to eq([
                                                          "/home/user/.venv/bin/python", "-m", "mlx_lm.server",
                                                          "--model", "/models/Qwen3.5-35B-A3B-4bit",
                                                          "--host", "127.0.0.1",
                                                          "--port", "8080",
                                                          "--decode-concurrency", "32",
                                                          "--prompt-concurrency", "8",
                                                        ])
    end

    it "omits --decode-concurrency when absent" do
      argv = supervisor.send(:build_argv, entry.except(:decode_concurrency))
      expect(argv).not_to include("--decode-concurrency")
    end

    it "omits --prompt-concurrency when absent" do
      argv = supervisor.send(:build_argv, entry.except(:prompt_concurrency))
      expect(argv).not_to include("--prompt-concurrency")
    end

    it "includes --prompt-cache-size when present" do
      argv = supervisor.send(:build_argv, entry.merge(prompt_cache_size: 4))
      expect(argv).to include("--prompt-cache-size", "4")
    end

    it "appends extra_args at end of argv" do
      argv = supervisor.send(:build_argv, entry.merge(extra_args: ["--max-tokens", "512"]))
      expect(argv.last(2)).to eq(["--max-tokens", "512"])
    end

    it "no llama-server flags present (-c, --parallel, --flash-attn, --jinja absent)" do
      argv = supervisor.send(:build_argv, entry)
      expect(argv).not_to include("-c")
      expect(argv).not_to include("--parallel")
      expect(argv).not_to include("--flash-attn")
      expect(argv).not_to include("--jinja")
      expect(argv).not_to include("--fit")
    end
  end

  # ── ModelRegistry — mlx fields ─────────────────────────────────────────────

  describe "ModelRegistry — mlx fields" do
    it "resolve returns the entry Hash for a known alias" do
      entry = registry.resolve("test-model")
      expect(entry).to be_a(Hash)
      expect(entry[:model_dir]).to eq("/fake/model")
      expect(entry[:port]).to eq(port)
    end

    it "resolve returns nil for unknown alias" do
      expect(registry.resolve("no-such-model")).to be_nil
    end

    it "config/models.yml carries mlx engine fields and has mlx default" do
      loaded = SpaceInferenceGateway::ModelRegistry.load
      expect(loaded.default_alias).to eq("qwen3-122b-a10b")
      expect(loaded.aliases).to include("qwen3-122b-a10b", "qwen3-35b-a3b")

      entry = loaded.resolve("qwen3-122b-a10b")
      expect(entry).to be_a(Hash)
      expect(entry[:engine]).to eq("mlx")
      expect(entry[:model_dir]).to be_a(String)
      expect(entry[:port]).to be_a(Integer)
      expect(entry[:venv]).to be_a(String)
    end

    it "model_dir and venv have ~ expanded" do
      entry = SpaceInferenceGateway::ModelRegistry.load.resolve("qwen3-122b-a10b")
      expect(entry[:model_dir]).to start_with("/")
      expect(entry[:venv]).to start_with("/")
    end
  end

  # ── AC1 — Spawn + readiness gate ───────────────────────────────────────────

  describe "#start (AC1)" do
    it "returns Failure(:unknown_model) for unregistered alias" do
      Async do
        result = supervisor.start("no-such-model")
        expect(result).to be_failure
        expect(result.failure).to eq(:unknown_model)
      end
    end

    it "spawns a real child (running? true, pid positive)" do
      Async do |task|
        task.with_timeout(10) do
          result = supervisor.start("test-model")
          expect(result).to be_success
          expect(supervisor.running?).to be true
          expect(supervisor.pid).to be_a(Integer).and(be_positive)
        end
      end
    end

    it "returns base_url and alias in Success value" do
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

    context "readiness timeout" do
      let(:unready_polls) { 99_999 }

      it "returns Failure(:readiness_timeout) and stops the child" do
        timeout_sup = SpaceInferenceGateway::InferenceServerSupervisor.new(
          registry: registry,
          timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
            readiness: 0.5, stop_grace: 0.5, poll_interval: 0.05,
          ),
          log_dir: Dir.tmpdir,
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

  # ── AC1 — Stop ─────────────────────────────────────────────────────────────

  describe "#stop (AC1)" do
    it "is safe to call when not running" do
      Async do
        expect(supervisor.running?).to be false
        expect { supervisor.stop }.not_to raise_error
      end
    end

    it "terminates process; running? false; pid gone" do
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
  end

  # ── AC1 — Swap ─────────────────────────────────────────────────────────────

  describe "#swap (AC1)" do
    let(:registry) do
      build_registry(
        {
          "model-a" => { "engine" => "mlx", "venv" => FAKE_INF_BINARY, "model_dir" => "/fake/a", "port" => port },
          "model-b" => { "engine" => "mlx", "venv" => FAKE_INF_BINARY, "model_dir" => "/fake/b", "port" => port2 },
        },
        "model-a",
      )
    end

    it "stops current and starts new; active_alias reflects swap target" do
      Async do |task|
        task.with_timeout(15) do
          supervisor.start("model-a")
          result = supervisor.swap(to: "model-b")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-b")
          expect(supervisor.running?).to be true
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

    it "swap from idle starts the target without requiring prior start" do
      Async do |task|
        task.with_timeout(10) do
          expect(supervisor.running?).to be false
          result = supervisor.swap(to: "model-a")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-a")
        end
      end
    end
  end
end
