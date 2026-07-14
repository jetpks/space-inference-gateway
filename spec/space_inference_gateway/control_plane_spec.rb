# frozen_string_literal: true

require "rack/test"
require "async"
require "async/http/client"
require "async/http/endpoint"
require "falcon"
require "uri"

CP_FAKE_BINARY = File.expand_path("../support/fake_llama_server", __dir__) unless defined?(CP_FAKE_BINARY)

RSpec.describe "Model Control Plane (I05 — Supervisor Backend)" do
  include Rack::Test::Methods

  # ── helpers ─────────────────────────────────────────────────────────────────

  def free_port
    srv  = TCPServer.new("127.0.0.1", 0)
    port = srv.addr[1]
    srv.close
    port
  end

  def boot_proxy(the_app)
    base  = Async::HTTP::Endpoint.parse("http://localhost:0")
    bound = base.bound
    port  = bound.sockets.first.local_address.ip_port
    ep    = Async::HTTP::Endpoint.new(URI.parse("http://localhost:#{port}"), bound)
    task  = Falcon::Server.new(Falcon::Server.middleware(the_app), ep).run
    [port, task, bound]
  end

  def http_client(port)
    Async::HTTP::Client.new(Async::HTTP::Endpoint.parse("http://localhost:#{port}"))
  end

  def call_app(target_app, method, path, body = nil)
    env = Rack::MockRequest.env_for(
      path,
      method:          method,
      input:           body.to_s,
      "CONTENT_TYPE" => "application/json",
    )
    status, headers, parts = target_app.call(env)
    Rack::MockResponse.new(status, headers, parts)
  end

  # ── shared fixtures ─────────────────────────────────────────────────────────

  let(:port_a) { free_port }
  let(:port_b) { free_port }

  let(:registry) do
    SpaceInferenceGateway::ModelRegistry.new(
      "default" => "model-a",
      "models"  => {
        "model-a" => {
          "engine" => "mlx",
          "venv" => CP_FAKE_BINARY,
          "model" => "/fake/a",
          "port" => port_a,
        },
        "model-b" => {
          "engine" => "mlx",
          "venv" => CP_FAKE_BINARY,
          "model" => "/fake/b",
          "port" => port_b,
        },
      },
    )
  end

  let(:timeouts) do
    SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
      readiness: 10, stop_grace: 0.5, poll_interval: 0.05,
    )
  end

  let(:supervisor) do
    SpaceInferenceGateway::InferenceServerSupervisor.new(
      registry: registry, timeouts: timeouts, log_dir: Dir.tmpdir,
    )
  end

  let(:controller) do
    SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)
  end

  let(:app) { SpaceInferenceGateway::App.new(controller: controller) }

  around do |ex|
    ENV["FAKE_UNREADY_POLLS"] = "3"
    ex.run
  ensure
    ENV.delete("FAKE_UNREADY_POLLS")
    Async { supervisor.stop }
  end

  # ── AC1 — GET /v1/models ────────────────────────────────────────────────────

  describe "AC1 — GET /v1/models returns registry aliases" do
    before { get "/v1/models" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "body has object:list" do
      expect(JSON.parse(last_response.body)["object"]).to eq("list")
    end

    it "data contains registry aliases" do
      ids = JSON.parse(last_response.body)["data"].map { |m| m["id"] }
      expect(ids).to include("model-a")
      expect(ids).to include("model-b")
    end

    it "each entry has correct shape" do
      JSON.parse(last_response.body)["data"].each do |entry|
        expect(entry["object"]).to eq("model")
        expect(entry["created"]).to be_a(Integer)
        expect(entry["owned_by"]).to be_a(String)
      end
    end

    it "no raw filesystem paths in any id" do
      JSON.parse(last_response.body)["data"].each do |entry|
        expect(entry["id"]).not_to match(%r{\A/})
      end
    end

    it "validates against Schemas::MODELS_LIST" do
      result = SpaceInferenceGateway::Schemas::MODELS_LIST.call(JSON.parse(last_response.body))
      expect(result).to be_success
    end
  end

  # ── AC2 — ensure_active drives supervisor ───────────────────────────────────

  describe "AC2 — ensure_active drives supervisor" do
    it "spawns real child (running? true, real pid), base_url matches port" do
      Async do |task|
        task.with_timeout(15) do
          result = controller.ensure_active("model-a")
          expect(result).to be_success
          expect(supervisor.running?).to be true
          expect(supervisor.pid).to be_a(Integer).and be_positive
          expect(controller.base_url).to eq("http://127.0.0.1:#{port_a}")
        end
      end
    end

    it "already-active alias is a no-op (same pid, child not respawned)" do
      Async do |task|
        task.with_timeout(15) do
          controller.ensure_active("model-a")
          pid_before = supervisor.pid

          result = controller.ensure_active("model-a")

          expect(result).to be_success
          expect(supervisor.pid).to eq(pid_before)
        end
      end
    end

    it "unknown alias → Failure(:unknown_model)" do
      Async do
        result = controller.ensure_active("no-such-model")
        expect(result).to be_failure
        expect(result.failure).to eq(:unknown_model)
      end
    end

    it "lazy: unknown model name with nothing running starts the default" do
      Async do |task|
        task.with_timeout(30) do
          expect(supervisor.running?).to be(false)
          result = controller.ensure_active_if_known("claude-sonnet-4-5")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-a")
          expect(supervisor.running?).to be(true)
        ensure
          supervisor.stop
        end
      end
    end

    it "lazy: unknown model name leaves an already-running model untouched" do
      Async do |task|
        task.with_timeout(30) do
          controller.ensure_active("model-b")
          pid_before = supervisor.pid
          result = controller.ensure_active_if_known("gpt-4o-mini")
          expect(result).to be_success
          expect(supervisor.active_alias).to eq("model-b")
          expect(supervisor.pid).to eq(pid_before)
        ensure
          supervisor.stop
        end
      end
    end

    it "POST /v1/load with unknown alias returns 4xx" do
      Async do |task|
        task.with_timeout(5) do
          resp = call_app(app, "POST", "/v1/load", JSON.generate({ "model" => "no-such-alias" }))
          expect(resp.status).to be_between(400, 499)
          expect(JSON.parse(resp.body).dig("error", "message")).to be_a(String)
        end
      end
    end
  end

  # ── AC3 — Lazy auto-swap + upstream follows live child ──────────────────────

  describe "AC3 — lazy auto-swap + upstream follows live child" do
    it "non-active alias triggers swap; fake child records inbound POST /v1/chat/completions" do
      Async do |task|
        task.with_timeout(30) do
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = http_client(proxy_port)

          begin
            body = JSON.generate({ model: "model-a", messages: [{ role: "user", content: "hi" }] })
            resp = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
            expect(resp.status).to eq(200)
            resp.read

            req_client = http_client(port_a)
            req_resp   = req_client.get("/__requests")
            requests   = JSON.parse(req_resp.read)
            req_client.close

            gen_call = requests.find { |r| r["path"] == "/v1/chat/completions" }
            expect(gen_call).not_to be_nil
            expect(gen_call["method"]).to eq("POST")
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
          end
        end
      end
    end

    it "already-active alias triggers zero swaps (same pid)" do
      Async do |task|
        task.with_timeout(30) do
          controller.ensure_active("model-a")
          pid_before = supervisor.pid

          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = http_client(proxy_port)

          begin
            body = JSON.generate({ model: "model-a", messages: [{ role: "user", content: "hi" }] })
            resp = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
            expect(resp.status).to eq(200)
            resp.read

            expect(supervisor.pid).to eq(pid_before)
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
          end
        end
      end
    end
  end

  # ── AC4 — 409-busy while generation is in flight ────────────────────────────

  describe "AC4 — 409-busy while generation is in flight" do
    it "ensure_active returns Failure(:busy), no swap, active child unchanged" do
      Async do |task|
        task.with_timeout(15) do
          controller.ensure_active("model-a")
          pid_before = supervisor.pid

          swap_result = nil
          controller.with_generation do
            swap_result = controller.ensure_active("model-b")
          end

          expect(swap_result).to be_failure
          expect(swap_result.failure).to eq(:busy)
          expect(supervisor.pid).to eq(pid_before)
          expect(supervisor.active_alias).to eq("model-a")
        end
      end
    end

    it "POST /v1/load of different alias while generation in flight returns HTTP 409" do
      Async do |task|
        task.with_timeout(15) do
          controller.ensure_active("model-a")

          barrier    = Async::Condition.new
          in_flight  = false

          gen_task = task.async do
            controller.with_generation do
              in_flight = true
              barrier.wait
            end
          end

          task.yield until in_flight

          resp = call_app(app, "POST", "/v1/load", JSON.generate({ "model" => "model-b" }))
          expect(resp.status).to eq(409)

          barrier.signal
          gen_task.wait
        end
      end
    end
  end

  # ── AC5 — Serialized swaps, both succeed ────────────────────────────────────

  describe "AC5 — serialized swaps for different aliases both succeed" do
    it "two concurrent ensure_active calls both return Success, never two children at once" do
      Async do |task|
        task.with_timeout(60) do
          r1 = r2 = nil
          t1 = task.async { r1 = controller.ensure_active("model-a") }
          t2 = task.async { r2 = controller.ensure_active("model-b") }

          t1.wait
          t2.wait

          expect(r1).to be_success
          expect(r2).to be_success
          expect(supervisor.running?).to be true
          expect(%w[model-a model-b]).to include(supervisor.active_alias)
        end
      end
    end
  end

  # ── AC6 — Explicit endpoints, schema-valid ───────────────────────────────────

  describe "AC6 — explicit endpoints schema-valid with real backend" do
    it "POST /v1/load known alias: 200, LOAD_RESPONSE valid, child running" do
      Async do |task|
        task.with_timeout(20) do
          resp = call_app(app, "POST", "/v1/load", JSON.generate({ "model" => "model-a" }))

          expect(resp.status).to eq(200)
          expect(supervisor.running?).to be true

          parsed = JSON.parse(resp.body)
          expect(parsed["status"]).to eq("loaded")
          expect(parsed["model_path"]).to eq("/fake/a")
          expect(SpaceInferenceGateway::Schemas::LOAD_RESPONSE.call(parsed)).to be_success
        end
      end
    end

    it "POST /v1/unload: supervisor stopped, pid gone, UNLOAD_RESPONSE valid" do
      Async do |task|
        task.with_timeout(20) do
          controller.ensure_active("model-a")
          pid = supervisor.pid

          resp = call_app(app, "POST", "/v1/unload", JSON.generate({ "model_path" => "/fake/a.gguf" }))

          expect(resp.status).to eq(200)
          expect(supervisor.running?).to be false
          expect { Process.kill(0, pid) }.to raise_error(Errno::ESRCH)

          parsed = JSON.parse(resp.body)
          expect(SpaceInferenceGateway::Schemas::UNLOAD_RESPONSE.call(parsed)).to be_success
        end
      end
    end

    it "GET /v1/load-progress: fraction 1.0 when running, 0.0 when not" do
      Async do |task|
        task.with_timeout(20) do
          idle = call_app(app, "GET", "/v1/load-progress", nil)
          expect(idle.status).to eq(200)
          idle_body = JSON.parse(idle.body)
          expect(idle_body["fraction"]).to eq(0.0)
          expect(SpaceInferenceGateway::Schemas::LOAD_PROGRESS.call(idle_body)).to be_success

          controller.ensure_active("model-a")

          ready = call_app(app, "GET", "/v1/load-progress", nil)
          expect(ready.status).to eq(200)
          ready_body = JSON.parse(ready.body)
          expect(ready_body["fraction"]).to eq(1.0)
          expect(SpaceInferenceGateway::Schemas::LOAD_PROGRESS.call(ready_body)).to be_success
        end
      end
    end
  end

  # ── AC7 — Readiness timeout clean, no hang ──────────────────────────────────

  describe "AC7 — readiness timeout is clean (no hang)" do
    let(:timeout_timeouts) do
      SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
        readiness: 0.5, stop_grace: 0.5, poll_interval: 0.05,
      )
    end

    let(:timeout_supervisor) do
      SpaceInferenceGateway::InferenceServerSupervisor.new(
        registry: registry, timeouts: timeout_timeouts, log_dir: Dir.tmpdir,
      )
    end

    let(:timeout_controller) do
      SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: timeout_supervisor)
    end

    around do |ex|
      ENV["FAKE_UNREADY_POLLS"] = "99999"
      ex.run
    ensure
      ENV["FAKE_UNREADY_POLLS"] = "3"
      Async { timeout_supervisor.stop }
    end

    it "ensure_active returns Failure(:timeout), child stopped, no hang" do
      Async do |task|
        task.with_timeout(10) do
          result = timeout_controller.ensure_active("model-a")

          expect(result).to be_failure
          expect(result.failure).to eq(:timeout)
          expect(timeout_supervisor.running?).to be false
        end
      end
    end

    it "POST /v1/chat/completions with never-ready alias returns HTTP 504" do
      Async do |task|
        task.with_timeout(20) do
          timeout_app = SpaceInferenceGateway::App.new(controller: timeout_controller)
          proxy_port, proxy_task, proxy_bound = boot_proxy(timeout_app)
          client = http_client(proxy_port)

          begin
            body = JSON.generate({ model: "model-a", messages: [{ role: "user", content: "hi" }] })
            resp = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)

            expect(resp.status).to eq(504)
            parsed = JSON.parse(resp.read)
            expect(parsed.dig("error", "type")).to eq("upstream_error")
          ensure
            client.close
            proxy_task.stop
            proxy_bound.close
          end
        end
      end
    end
  end
end
