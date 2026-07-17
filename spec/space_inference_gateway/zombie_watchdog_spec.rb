# frozen_string_literal: true

require "rack/test"
require "socket"
require_relative "../support/fake_upstream_server"

ZOMBIE_FAKE_BINARY = File.expand_path("../support/fake_llama_server", __dir__) unless defined?(ZOMBIE_FAKE_BINARY)

# A supervisor double that counts #swap calls and yields briefly inside one (a
# real, but short, async suspension point) — for proving the watchdog's
# exactly-once-under-concurrency and busy-guard-bypass behavior directly
# against ModelController. Genuinely racing byte-level sockets to exercise a
# single-threaded-fiber-scheduler invariant would be fragile without proving
# anything these direct calls don't already cover.
CountingSupervisor = Struct.new(:active_alias, :swap_calls, :running_flag) do
  include Dry::Monads[:result]

  def running? = running_flag
  def base_url = "http://unused"
  def start(_alias_name) = Success(nil)
  def stop = nil

  def swap(to:)
    self.swap_calls += 1
    Async::Task.current.sleep(0.05)
    self.active_alias = to
    Success(to)
  end
end

# Zombie watchdog specs (I04 AC3). The end-to-end case drives a real
# supervisor + fake_llama_server subprocess against a RawUpstream that never
# responds, proving the real stop->spawn->readiness restart fires. The
# trickier concurrency/reset/busy-bypass semantics are proven directly
# against ModelController with CountingSupervisor above.
RSpec.describe "Zombie watchdog (I04 AC3)" do
  include FakeUpstreamServer

  around do |example|
    Async do |task|
      @task = task
      example.run
    end
  end

  before { SpaceInferenceGateway::Metrics.reset_all }

  it "ModelController::ZOMBIE_RESTART_THRESHOLD defaults to 2 (env-overridable via ZOMBIE_RESTART_THRESHOLD)" do
    expect(ENV.fetch("ZOMBIE_RESTART_THRESHOLD", nil)).to be_nil
    expect(SpaceInferenceGateway::ModelController::ZOMBIE_RESTART_THRESHOLD).to eq(2)
  end

  def free_port
    srv  = TCPServer.new("127.0.0.1", 0)
    port = srv.addr[1]
    srv.close
    port
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

  # ── ModelController — zombie streak semantics (unit) ────────────────────────

  describe "ModelController — zombie streak semantics" do
    def build_controller(running: true)
      supervisor = CountingSupervisor.new("alias-a", 0, running)
      controller = SpaceInferenceGateway::ModelController.new(registry: fixture_registry, supervisor: supervisor)
      [controller, supervisor]
    end

    it "a lone timeout below the threshold does not restart" do
      controller, supervisor = build_controller
      controller.note_headers_timeout
      expect(supervisor.swap_calls).to eq(0)
    end

    it "restarts exactly once at the threshold, then resets the streak" do
      controller, supervisor = build_controller
      controller.note_headers_timeout # streak 1
      controller.note_headers_timeout # streak 2 -> restart, reset to 0
      expect(supervisor.swap_calls).to eq(1)
      expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(1)

      controller.note_headers_timeout # post-reset: streak 1, below threshold again
      expect(supervisor.swap_calls).to eq(1)
    end

    it "a successful headers-received resets the streak, so an interleaved success below threshold no-ops" do
      controller, supervisor = build_controller
      controller.note_headers_timeout  # streak 1
      controller.note_headers_received # reset to 0
      controller.note_headers_timeout  # streak 1 again (below threshold 2)
      expect(supervisor.swap_calls).to eq(0)
    end

    it "concurrent timeouts racing to the threshold do not stack restarts" do
      controller, supervisor = build_controller
      # 3 signals for a threshold of 2: the 2nd crosses and resets the streak
      # before its own restart (a real async yield inside #swap) completes;
      # the 3rd lands post-reset and does not re-cross.
      tasks = Array.new(3) { @task.async { controller.note_headers_timeout } }
      tasks.each(&:wait)
      expect(supervisor.swap_calls).to eq(1)
    end

    it "restart proceeds while active generations are positive (busy guard bypassed)" do
      controller, supervisor = build_controller
      controller.begin_generation
      controller.begin_generation
      controller.note_headers_timeout
      controller.note_headers_timeout # crosses threshold
      expect(supervisor.swap_calls).to eq(1)
    end

    it "no restart fires when no child is running" do
      controller, supervisor = build_controller(running: false)
      controller.note_headers_timeout
      controller.note_headers_timeout
      controller.note_headers_timeout
      expect(supervisor.swap_calls).to eq(0)
    end
  end

  # ── Non-feeding paths — buffered 504s and mid-stream idle timeouts ─────────

  describe "non-feeding paths do not touch the counter" do
    it "buffered-path (non-stream) timeouts, repeated past the threshold, do not restart" do
      @task.with_timeout(6) do
        supervisor = CountingSupervisor.new("diffusiongemma", 0, true)
        controller = SpaceInferenceGateway::ModelController.new(registry: fixture_registry, supervisor: supervisor)

        2.times do
          upstream = FakeUpstreamServer::RawUpstream.new(@task)
          upstream.accept { |_sock| @task.sleep(60) } # never responds

          upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 0.3)
          app = SpaceInferenceGateway::App.new(upstream_client: upstream_client, controller: controller)

          resp = call_app(app, "POST", "/v1/chat/completions", JSON.generate({ model: "any", messages: [] }))
          expect(resp.status).to eq(504)
        ensure
          upstream&.stop
        end

        expect(supervisor.swap_calls).to eq(0)
        expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(0)
      end
    end

    it "mid-stream idle timeouts (headers + chunk then stall), repeated past the threshold, do not restart" do
      @task.with_timeout(10) do
        supervisor = CountingSupervisor.new("diffusiongemma", 0, true)
        controller = SpaceInferenceGateway::ModelController.new(registry: fixture_registry, supervisor: supervisor)
        first_event = fixture("oai_s.txt").split(/(?<=\n\n)/).reject(&:empty?).first

        2.times do
          upstream = FakeUpstreamServer::RawUpstream.new(@task)
          upstream.accept do |sock|
            sse_headers(sock)
            http_chunk(sock, first_event)
            @task.sleep(60) # headers + one chunk arrive, then stall
          end

          upstream_client = SpaceInferenceGateway::UpstreamClient.new(base_url: upstream.base_url, idle_timeout: 0.3)
          app = SpaceInferenceGateway::App.new(upstream_client: upstream_client, controller: controller)
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = client_for(proxy_port)
          body = JSON.generate({ model: "diffusiongemma", messages: [], stream: true })

          response = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(response.status).to eq(200)
          nil while response.body.read # drain to natural (idle-timeout-triggered) EOF
        ensure
          client&.close
          proxy_task&.stop
          proxy_bound&.close
          upstream&.stop
        end

        expect(supervisor.swap_calls).to eq(0)
        expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(0)
      end
    end
  end

  # ── End-to-end — real supervisor + subprocess, fake upstream never responds ─

  describe "end-to-end — consecutive streaming headers-timeouts restart the real child" do
    it "2 consecutive never-respond streams restart the real child exactly once; " \
       "interleaved success and a lone follow-up timeout do not restart again" do
      @task.with_timeout(30) do
        port = free_port
        registry = SpaceInferenceGateway::ModelRegistry.new(
          "default" => "zombie-test",
          "models"  => {
            "zombie-test" => { "engine" => "mlx", "venv" => ZOMBIE_FAKE_BINARY, "model" => "/fake/z", "port" => port },
          },
        )
        supervisor = SpaceInferenceGateway::InferenceServerSupervisor.new(
          registry: registry,
          timeouts: SpaceInferenceGateway::InferenceServerSupervisor::Timeouts.new(
            readiness: 10, stop_grace: 0.5, poll_interval: 0.05,
          ),
          log_dir: Dir.tmpdir,
        )
        controller = SpaceInferenceGateway::ModelController.new(registry: registry, supervisor: supervisor)

        begin
          controller.ensure_active("zombie-test")
          first_pid = supervisor.pid
          expect(first_pid).to be_a(Integer)

          upstream = FakeUpstreamServer::RawUpstream.new(@task)
          upstream.accept { |_sock| @task.sleep(60) } # request 1: never responds

          zombie_client = SpaceInferenceGateway::UpstreamClient.new(
            base_url: upstream.base_url, idle_timeout: 10, headers_timeout: 0.3,
          )
          app = SpaceInferenceGateway::App.new(upstream_client: zombie_client, controller: controller)
          proxy_port, proxy_task, proxy_bound = boot_proxy(app)
          client = client_for(proxy_port)
          body = JSON.generate({ model: "zombie-test", messages: [], stream: true })

          resp1 = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(resp1.status).to eq(504)
          resp1.read

          expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(0)
          expect(supervisor.pid).to eq(first_pid) # only 1 timeout so far — no restart yet

          upstream.accept { |_sock| @task.sleep(60) } # request 2: never responds — crosses threshold
          resp2 = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(resp2.status).to eq(504)
          resp2.read

          expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(1)
          expect(supervisor.running?).to be true
          expect(supervisor.active_alias).to eq("zombie-test")
          second_pid = supervisor.pid
          expect(second_pid).not_to eq(first_pid) # real restart: new pid

          # Interleaved success — point directly at the (real, restarted)
          # child, whose canned response resets the streak.
          healthy_client = SpaceInferenceGateway::UpstreamClient.new(
            base_url: supervisor.base_url, idle_timeout: 10, headers_timeout: 5,
          )
          healthy_app = SpaceInferenceGateway::App.new(upstream_client: healthy_client, controller: controller)
          healthy_port, healthy_task, healthy_bound = boot_proxy(healthy_app)
          healthy_http = client_for(healthy_port)
          resp3 = healthy_http.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(resp3.status).to eq(200)
          resp3.read
          healthy_http.close
          healthy_task.stop
          healthy_bound.close

          # One more timeout, below threshold — must not restart a second time.
          upstream.accept { |_sock| @task.sleep(60) }
          resp4 = client.post("/v1/chat/completions", [["content-type", "application/json"]], body)
          expect(resp4.status).to eq(504)
          resp4.read

          expect(SpaceInferenceGateway::Metrics::CHILD_ZOMBIE_RESTARTS.get).to eq(1)
          expect(supervisor.pid).to eq(second_pid)
        ensure
          client&.close
          proxy_task&.stop
          proxy_bound&.close
          upstream&.stop
          supervisor.stop
        end
      end
    end
  end
end
