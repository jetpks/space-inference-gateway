# frozen_string_literal: true

require "async"
require "socket"
require "tmpdir"

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
          "model" => "/fake/model",
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

  # ── AC1 — exact mlx argv (frozen I08) ────────────────────────────────────

  describe "#build_argv — mlx engine (AC1)" do
    let(:entry) do
      {
        venv:               "/home/user/.venv/bin/python",
        model:              "/models/Qwen3.5-35B-A3B-4bit",
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

    it "entry without :engine key defaults to mlx path" do
      argv = supervisor.send(:build_argv, entry)
      expect(argv).to include("-m", "mlx_lm.server")
    end
  end

  # ── AC1 — exact optiq argv ────────────────────────────────────────────────

  describe "#build_argv — optiq engine (AC1)" do
    let(:optiq_entry) do
      {
        engine:         "optiq",
        venv:           "/home/user/.venv-optiq/bin/optiq",
        model:          "mlx-community/Qwen3.6-27B-OptiQ-4bit",
        port:           8080,
        mtp:            true,
        mtp_depth:      2,
        max_concurrent: 8,
      }
    end

    it "builds exact optiq serve argv for qwen3-27b-optiq entry" do
      expect(supervisor.send(:build_argv, optiq_entry)).to eq([
                                                                "/home/user/.venv-optiq/bin/optiq", "serve",
                                                                "--model", "mlx-community/Qwen3.6-27B-OptiQ-4bit",
                                                                "--host", "127.0.0.1",
                                                                "--port", "8080",
                                                                "--mtp",
                                                                "--mtp-depth", "2",
                                                                "--no-auth",
                                                                "--max-concurrent", "8",
                                                              ])
    end

    it "omits --mtp and --mtp-depth when mtp is absent/false" do
      argv = supervisor.send(:build_argv, optiq_entry.except(:mtp, :mtp_depth))
      expect(argv).not_to include("--mtp")
      expect(argv).not_to include("--mtp-depth")
    end

    it "includes --mtp but omits --mtp-depth when mtp_depth is absent" do
      argv = supervisor.send(:build_argv, optiq_entry.except(:mtp_depth))
      expect(argv).to include("--mtp")
      expect(argv).not_to include("--mtp-depth")
    end

    it "always includes --no-auth" do
      argv = supervisor.send(:build_argv, optiq_entry)
      expect(argv).to include("--no-auth")
    end

    it "omits --max-concurrent when absent" do
      argv = supervisor.send(:build_argv, optiq_entry.except(:max_concurrent))
      expect(argv).not_to include("--max-concurrent")
    end

    it "appends extra_args at end of argv" do
      argv = supervisor.send(:build_argv, optiq_entry.merge(extra_args: ["--context-scale", "2"]))
      expect(argv.last(2)).to eq(["--context-scale", "2"])
    end

    it "does not include mlx_lm.server flags" do
      argv = supervisor.send(:build_argv, optiq_entry)
      expect(argv).not_to include("-m")
      expect(argv).not_to include("mlx_lm.server")
      expect(argv).not_to include("--decode-concurrency")
      expect(argv).not_to include("--prompt-concurrency")
    end
  end

  # ── AC1 — exact mlx-vlm argv ──────────────────────────────────────────────

  describe "#build_argv — mlx-vlm engine (AC1)" do
    let(:mlx_vlm_entry) do
      {
        engine:          "mlx-vlm",
        venv:            "/home/user/.venv-mlx-vlm/bin/mlx_vlm.server",
        model:           "mlx-community/Qwen3.8-27B-mxfp8",
        port:            8080,
        enable_thinking: true,
        draft_model:     "mlx-community/Qwen3.8-27B-MTP-mxfp8",
        draft_kind:      "mtp",
      }
    end

    it "builds exact mlx_vlm.server argv for qwen3.8-27b-mxfp8 entry" do
      expect(supervisor.send(:build_argv, mlx_vlm_entry)).to eq([
                                                                  "/home/user/.venv-mlx-vlm/bin/mlx_vlm.server",
                                                                  "--model", "mlx-community/Qwen3.8-27B-mxfp8",
                                                                  "--host", "127.0.0.1",
                                                                  "--port", "8080",
                                                                  "--enable-thinking",
                                                                  "--draft-model", "mlx-community/Qwen3.8-27B-MTP-mxfp8",
                                                                  "--draft-kind", "mtp",
                                                                ])
    end

    it "invokes venv directly with no interpreter prefix (no -m, no mlx_lm.server)" do
      argv = supervisor.send(:build_argv, mlx_vlm_entry)
      expect(argv.first).to eq(mlx_vlm_entry[:venv])
      expect(argv).not_to include("-m")
      expect(argv).not_to include("mlx_lm.server")
    end

    it "omits --enable-thinking, --draft-model, --draft-kind when their keys are absent" do
      argv = supervisor.send(:build_argv, mlx_vlm_entry.except(:enable_thinking, :draft_model, :draft_kind))
      expect(argv).not_to include("--enable-thinking")
      expect(argv).not_to include("--draft-model")
      expect(argv).not_to include("--draft-kind")
    end

    it "omits --draft-model when only draft_kind is present" do
      argv = supervisor.send(:build_argv, mlx_vlm_entry.except(:draft_model))
      expect(argv).not_to include("--draft-model")
      expect(argv).to include("--draft-kind", "mtp")
    end
  end

  # ── AC2 — unrecognized engine fails loudly ────────────────────────────────

  describe "#build_argv — unrecognized engine (AC2)" do
    it "raises for an engine that is neither a recognized kind nor absent" do
      entry = { engine: "definitely-not-an-engine", model: "M", port: 8080, venv: "/tmp/x/bin/python" }
      expect { supervisor.send(:build_argv, entry) }.to raise_error(StandardError)
    end

    it "does not silently fall back to building mlx_lm.server argv for an unknown engine" do
      entry = { engine: "vllm", model: "M", port: 8080, venv: "/tmp/x/bin/python" }
      expect { supervisor.send(:build_argv, entry) }.to raise_error(StandardError)
    end
  end

  # ── AC4 — environment derived from the registry entry ────────────────────

  describe "#build_env (AC4)" do
    it "maps apc_enabled and apc_exact_cache_entries to APC_ENABLED and APC_EXACT_CACHE_ENTRIES" do
      entry = { engine: "mlx-vlm", apc_enabled: true, apc_exact_cache_entries: 16 }
      expect(supervisor.send(:build_env, entry)).to eq("APC_ENABLED" => "1", "APC_EXACT_CACHE_ENTRIES" => "16")
    end

    it "leaves the environment unchanged when neither key is present" do
      entry = { engine: "mlx", model: "M", port: 8080, venv: "/tmp/x/bin/python" }
      expect(supervisor.send(:build_env, entry)).to eq({})
    end

    it "omits APC_EXACT_CACHE_ENTRIES when apc_exact_cache_entries is absent" do
      entry = { engine: "mlx-vlm", apc_enabled: true }
      expect(supervisor.send(:build_env, entry)).to eq("APC_ENABLED" => "1")
    end

    it "omits APC_ENABLED when apc_enabled is absent" do
      entry = { engine: "mlx-vlm", apc_exact_cache_entries: 16 }
      expect(supervisor.send(:build_env, entry)).to eq("APC_EXACT_CACHE_ENTRIES" => "16")
    end
  end

  # ── ModelRegistry — mlx fields ─────────────────────────────────────────────

  describe "ModelRegistry — mlx fields" do
    it "resolve returns the entry Hash for a known alias" do
      entry = registry.resolve("test-model")
      expect(entry).to be_a(Hash)
      expect(entry[:model]).to eq("/fake/model")
      expect(entry[:port]).to eq(port)
    end

    it "resolve returns nil for unknown alias" do
      expect(registry.resolve("no-such-model")).to be_nil
    end

    it "config/models.yml has qwen3.8-27b-mxfp8 default and carries mlx + optiq + mlx-vlm aliases" do
      loaded = SpaceInferenceGateway::ModelRegistry.load
      expect(loaded.default_alias).to eq("qwen3.8-27b-mxfp8")
      expect(loaded.aliases).to include("qwen3.8-27b-mxfp8", "qwen3-27b-optiq", "hermes-4-70b",
                                        "qwen3-122b-a10b", "qwen3-35b-a3b",)

      optiq_entry = loaded.resolve("qwen3-27b-optiq")
      expect(optiq_entry[:engine]).to eq("optiq")
      expect(optiq_entry[:model]).to eq("mlx-community/Qwen3.6-27B-OptiQ-4bit")
      expect(optiq_entry[:port]).to be_a(Integer)
      expect(optiq_entry[:mtp]).to eq(true)
      expect(optiq_entry[:mtp_depth]).to eq(2)
      expect(optiq_entry[:max_concurrent]).to eq(8)

      mlx_entry = loaded.resolve("qwen3-122b-a10b")
      expect(mlx_entry[:engine]).to eq("mlx")
      expect(mlx_entry[:model]).to be_a(String)

      mlx_vlm_entry = loaded.resolve("qwen3.8-27b-mxfp8")
      expect(mlx_vlm_entry[:engine]).to eq("mlx-vlm")
      expect(mlx_vlm_entry[:model]).to eq("mlx-community/Qwen3.8-27B-mxfp8")
      expect(mlx_vlm_entry[:apc_enabled]).to eq(true)
      expect(mlx_vlm_entry[:apc_exact_cache_entries]).to eq(16)
      expect(mlx_vlm_entry[:draft_model]).to eq("mlx-community/Qwen3.8-27B-MTP-mxfp8")
      expect(mlx_vlm_entry[:draft_kind]).to eq("mtp")
    end

    it "venv has ~ expanded; model is the repo id (not path-expanded)" do
      entry = SpaceInferenceGateway::ModelRegistry.load.resolve("qwen3-122b-a10b")
      expect(entry[:model]).to eq("mlx-community/Qwen3.5-122B-A10B-4bit")
      expect(entry[:venv]).to start_with("/")
    end

    it "optiq venv has ~ expanded; model is the HF repo id (not path-expanded)" do
      entry = SpaceInferenceGateway::ModelRegistry.load.resolve("qwen3-27b-optiq")
      expect(entry[:venv]).to start_with("/")
      expect(entry[:model]).to eq("mlx-community/Qwen3.6-27B-OptiQ-4bit")
    end
  end

  # ── AC1 — Optiq spawn + readiness gate ────────────────────────────────────
  # The fake_llama_server binary is engine-agnostic: it parses --port from
  # any argv (ignoring leading subcommands like "serve") and responds to GET
  # /health with 200 after N unready polls. Register an optiq entry pointing
  # at the fake binary to verify the supervisor's spawn + health loop works.

  describe "#start — optiq engine (AC1)" do
    let(:optiq_registry) do
      build_registry(
        {
          "fake-optiq" => {
            "engine" => "optiq",
            "venv" => FAKE_INF_BINARY,
            "model" => "mlx-community/Fake-OptiQ",
            "port" => port,
          },
        },
        "fake-optiq",
      )
    end

    let(:optiq_supervisor) do
      SpaceInferenceGateway::InferenceServerSupervisor.new(
        registry: optiq_registry,
        timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
          readiness: 10, stop_grace: 0.5, poll_interval: 0.05,
        ),
        log_dir: Dir.tmpdir,
      )
    end

    around do |ex|
      ex.run
    ensure
      Async { optiq_supervisor.stop }
    end

    it "spawns the fake optiq child, passes health gate, returns Success" do
      Async do |task|
        task.with_timeout(10) do
          result = optiq_supervisor.start("fake-optiq")
          expect(result).to be_success
          expect(optiq_supervisor.running?).to be true
          expect(optiq_supervisor.active_alias).to eq("fake-optiq")
        end
      end
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

    it "verified kill (AC6): by the time #stop returns, the port is confirmed released" do
      Async do |task|
        task.with_timeout(10) do
          supervisor.start("test-model")
          expect(supervisor.running?).to be true

          supervisor.stop

          # No EADDRINUSE — a real listener can bind the instant #stop returns,
          # proving the predecessor's port was actually released, not merely
          # assumed dead after a fixed sleep.
          rebound = TCPServer.new("127.0.0.1", port)
          rebound.close
        end
      end
    end
  end

  # ── AC3 — Child death is observed ───────────────────────────────────────────

  describe "child death is observed (AC3)" do
    it "an externally-killed child is reflected by running?, and the next request respawns cleanly" do
      Async do |task|
        task.with_timeout(10) do
          supervisor.start("test-model")
          first_pid = supervisor.pid
          expect(first_pid).to be_a(Integer)

          # Simulate a crash — e.g. the mlx_lm.server generate-thread malloc
          # crash from the studio — bypassing the supervisor entirely.
          Process.kill(:KILL, first_pid)
          task.sleep(0.05) while supervisor.running?

          expect(supervisor.running?).to be false

          result = supervisor.start("test-model")
          expect(result).to be_success
          expect(supervisor.running?).to be true
          expect(supervisor.pid).not_to eq(first_pid)
        end
      end
    end
  end

  # ── AC5 — Per-model readiness budget ────────────────────────────────────────

  describe "per-model readiness budget (AC5)" do
    let(:budget_registry) do
      build_registry(
        {
          "budgeted-model" => {
            "engine" => "mlx", "venv" => FAKE_INF_BINARY, "model" => "/fake/budgeted", "port" => port,
            "readiness_timeout" => readiness_timeout,
          },
        },
        "budgeted-model",
      )
    end

    let(:budget_supervisor) do
      SpaceInferenceGateway::InferenceServerSupervisor.new(
        registry: budget_registry,
        timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
          readiness: supervisor_readiness, stop_grace: 0.5, poll_interval: 0.05,
        ),
        log_dir: Dir.tmpdir,
      )
    end

    around do |ex|
      ex.run
    ensure
      Async { budget_supervisor.stop }
    end

    context "the per-model budget is shorter than the supervisor default" do
      let(:unready_polls) { 99_999 } # never ready
      let(:supervisor_readiness) { 10 }
      let(:readiness_timeout)    { 0.3 }

      it "times out on the shorter per-model budget, not the longer default" do
        Async do |task|
          task.with_timeout(5) do
            t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            result = budget_supervisor.start("budgeted-model")
            elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

            expect(result).to be_failure
            expect(result.failure).to eq(:readiness_timeout)
            expect(budget_supervisor.running?).to be false
            expect(elapsed).to be < 3 # bounded by the 0.3s override, not the 10s default
          end
        end
      end
    end

    context "the per-model budget is longer than the supervisor default" do
      let(:unready_polls) { 3 } # ready after 3 * 0.05s poll_interval ≈ 150ms
      let(:supervisor_readiness) { 0.05 } # shorter than the time-to-ready
      let(:readiness_timeout)    { 5 }

      it "a slow load within its declared budget is not killed" do
        Async do |task|
          task.with_timeout(5) do
            result = budget_supervisor.start("budgeted-model")

            expect(result).to be_success
            expect(budget_supervisor.running?).to be true
          end
        end
      end
    end
  end

  # ── AC7 — Startup port reap ──────────────────────────────────────────────────

  describe "startup port reap (AC7)" do
    it "reaps a pre-existing (untracked) listener on the target port before its first spawn" do
      Async do |task|
        task.with_timeout(15) do
          orphan_pid = Process.spawn(FAKE_INF_BINARY, "--port", port.to_s, out: File::NULL, err: File::NULL)
          Process.detach(orphan_pid)

          task.with_timeout(5) do
            loop do
              TCPSocket.new("127.0.0.1", port).close
              break
            rescue Errno::ECONNREFUSED
              task.sleep(0.02)
            end
          end

          result = supervisor.start("test-model")

          expect(result).to be_success
          expect(supervisor.running?).to be true
          expect(supervisor.pid).not_to eq(orphan_pid)
          expect { Process.kill(0, orphan_pid) }.to raise_error(Errno::ESRCH)
        ensure
          begin
            Process.kill(:KILL, orphan_pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end

  # ── AC1 — Swap ─────────────────────────────────────────────────────────────

  describe "#swap (AC1)" do
    let(:registry) do
      build_registry(
        {
          "model-a" => { "engine" => "mlx", "venv" => FAKE_INF_BINARY, "model" => "/fake/a", "port" => port },
          "model-b" => { "engine" => "mlx", "venv" => FAKE_INF_BINARY, "model" => "/fake/b", "port" => port2 },
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

  # ── I04 AC4 — child log location ─────────────────────────────────────────

  describe "child log location (I04 AC4)" do
    it "defaults to ~/Library/Logs/space-inference-gateway when ENGINE_LOG_DIR is unset" do
      expect(ENV.fetch("ENGINE_LOG_DIR", nil)).to be_nil
      default_only_supervisor = SpaceInferenceGateway::InferenceServerSupervisor.new(registry: registry)
      expect(default_only_supervisor.send(:default_log_dir)).to(
        eq(File.expand_path("~/Library/Logs/space-inference-gateway")),
      )
    end

    it "honors ENGINE_LOG_DIR for the default log_dir, writing real child output there" do
      Dir.mktmpdir do |custom_dir|
        ENV["ENGINE_LOG_DIR"] = custom_dir
        override_supervisor = SpaceInferenceGateway::InferenceServerSupervisor.new(
          registry: registry,
          timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
            readiness: 10, stop_grace: 0.5, poll_interval: 0.05,
          ),
        )

        Async do |task|
          task.with_timeout(10) do
            result = override_supervisor.start("test-model")
            expect(result).to be_success

            log_path = File.join(custom_dir, "test-model.log")
            expect(File.exist?(log_path)).to be true
          end
        ensure
          override_supervisor.stop
        end
      ensure
        ENV.delete("ENGINE_LOG_DIR")
      end
    end
  end
end
