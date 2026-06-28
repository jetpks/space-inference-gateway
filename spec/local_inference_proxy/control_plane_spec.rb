# frozen_string_literal: true

require "rack/test"
require "async"

RSpec.describe "Model Control Plane" do
  include Rack::Test::Methods

  let(:cp_status_json)      { fixture("cp_status.json") }
  let(:cp_status)           { JSON.parse(cp_status_json) }
  let(:cp_progress_idle_json) { fixture("cp_load_progress.json") }
  let(:cp_progress_done)    { { "phase" => nil, "bytes_loaded" => 0, "bytes_total" => 0, "fraction" => 1.0 } }

  # Status with qwen as the active model (diffusiongemma needs swap to become active).
  let(:cp_status_qwen_json) do
    JSON.generate(cp_status.merge(
                    "active_model"       => "/Users/lemonslut/.lmstudio/models/unsloth/Qwen3.6-27B-MTP-GGUF",
                    "model_identifier"   => "/Users/lemonslut/.lmstudio/models/unsloth/Qwen3.6-27B-MTP-GGUF",
                    "is_diffusion"       => false,
                    "supports_reasoning" => true,
                    "loaded"             => ["/Users/lemonslut/.lmstudio/models/unsloth/Qwen3.6-27B-MTP-GGUF"],
                  ))
  end

  # Status with an unknown model active (neither alias is active).
  let(:cp_status_neither_json) do
    JSON.generate(cp_status.merge(
                    "active_model"     => "/some/other/model",
                    "model_identifier" => "/some/other/model",
                    "loaded"           => ["/some/other/model"],
                  ))
  end

  let(:registry) do
    LocalInferenceProxy::ModelRegistry.new(
      "default" => "diffusiongemma",
      "models"  => {
        "diffusiongemma" => { "model_path" => "unsloth/diffusiongemma-26B-A4B-it-GGUF", "gguf_variant" => "Q8_0" },
        "qwen3.6-27b" => { "model_path" => "unsloth/Qwen3.6-27B-MTP-GGUF" },
      },
    )
  end

  # Default cp_fn: diffusiongemma is active, progress is idle.
  let(:default_cp_fn) do
    lambda do |_method, path, _body|
      case path
      when "/api/inference/status"   then [cp_status_json, 200, {}]
      when "/v1/load-progress"       then [cp_progress_idle_json, 200, {}]
      when "/v1/load"                then ["{}", 200, {}]
      when "/v1/unload"              then [JSON.generate({ "status" => "ok" }), 200, {}]
      else ["not found", 404, {}]
      end
    end
  end

  let(:controller) do
    LocalInferenceProxy::ModelController.new(
      registry:      registry,
      cp_fn:         default_cp_fn,
      load_timeout:  5,
      poll_interval: 0,
    )
  end

  let(:oai_response) { fixture("oai_ns.json") }
  let(:ant_response) { fixture("ant_ns.json") }

  let(:upstream_fn) do
    lambda do |path, _body|
      case path
      when "/v1/chat/completions" then [oai_response, 200, {}]
      when "/v1/messages"         then [ant_response, 200, {}]
      else ["not found", 404, {}]
      end
    end
  end

  let(:app) do
    LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: controller)
  end

  # Helper: call a specific app instance and return a Rack::MockResponse.
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

  # Helper: build a load-tracking cp_fn.
  # returns [load_calls_array, cp_fn] where cp_fn uses the provided status_fn.
  def tracking_cp_fn(status_fn:, progress_fn: nil)
    load_calls = []
    pf = progress_fn || ->(_) { [JSON.generate(cp_progress_done), 200, {}] }
    fn = lambda do |method, path, body|
      case [method, path]
      when ["POST", "/v1/load"]
        load_calls << (body ? JSON.parse(body) : {})
        ["{}", 200, {}]
      when ["GET", "/api/inference/status"]
        status_fn.call
      when ["GET", "/v1/load-progress"]
        pf.call(load_calls)
      when ["POST", "/v1/unload"]
        [JSON.generate({ "status" => "ok" }), 200, {}]
      else
        ["{}", 200, {}]
      end
    end
    [load_calls, fn]
  end

  # ── AC1: GET /v1/models registry shape ─────────────────────────────────────

  describe "AC1 — GET /v1/models returns registry aliases in OpenAI list shape" do
    before { get "/v1/models" }

    it "returns 200" do
      expect(last_response.status).to eq(200)
    end

    it "body has object:list" do
      expect(JSON.parse(last_response.body)["object"]).to eq("list")
    end

    it "data contains registry aliases as ids" do
      ids = JSON.parse(last_response.body)["data"].map { |m| m["id"] }
      expect(ids).to include("diffusiongemma")
      expect(ids).to include("qwen3.6-27b")
    end

    it "each entry has object:model, integer created, string owned_by" do
      JSON.parse(last_response.body)["data"].each do |entry|
        expect(entry["object"]).to eq("model")
        expect(entry["created"]).to be_a(Integer)
        expect(entry["owned_by"]).to be_a(String)
      end
    end

    it "no raw filesystem paths in any id" do
      JSON.parse(last_response.body)["data"].each do |entry|
        expect(entry["id"]).not_to include("/Users/")
        expect(entry["id"]).not_to match(%r{\A/})
      end
    end

    it "validates against MODELS_LIST schema" do
      body   = JSON.parse(last_response.body)
      result = LocalInferenceProxy::Schemas::MODELS_LIST.call(body)
      expect(result).to be_success
    end
  end

  # ── AC2: Active-vs-requested matching (real cp_status.json) ─────────────────

  describe "AC2 — active_matches? tolerant resolution against cp_status.json" do
    it "recognizes diffusiongemma alias as already-active (full-path in status)" do
      result = controller.ensure_active("diffusiongemma")
      expect(result).to be_success
    end

    it "a request naming the active alias triggers NO upstream /v1/load" do
      load_calls, cp_fn = tracking_cp_fn(status_fn: -> { [cp_status_json, 200, {}] })
      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      ctrl.ensure_active("diffusiongemma")
      expect(load_calls).to be_empty
    end

    it "recognizes qwen3.6-27b alias as NOT active when diffusiongemma is loaded (triggers swap)" do
      # With diffusion always active, swap to qwen times out (never readies)
      ctrl = LocalInferenceProxy::ModelController.new(
        registry:      registry,
        cp_fn:         default_cp_fn,
        load_timeout:  0,
        poll_interval: 0,
      )
      result = ctrl.ensure_active("qwen3.6-27b")
      expect(result).to be_failure
      # Either timeout or upstream_error — but NOT :already_active (no-op)
      expect(result.failure).not_to be_nil
    end
  end

  # ── AC3: Per-model normalization mode driven by status fields ───────────────

  describe "AC3 — normalization mode from active model status" do
    it "is_diffusion:true is reported from cp_status.json" do
      controller.ensure_active("diffusiongemma")
      expect(controller.active_mode[:is_diffusion]).to be(true)
    end

    it "supports_reasoning:true is reported from cp_status.json" do
      controller.ensure_active("diffusiongemma")
      expect(controller.active_mode[:supports_reasoning]).to be(true)
    end

    it "is_diffusion:false is reported from a synthetic AR status" do
      ar_status = cp_status.merge("is_diffusion" => false, "supports_reasoning" => true)
      ar_fn     = ->(_, path, _) { path == "/api/inference/status" ? [JSON.generate(ar_status), 200, {}] : ["{}", 200, {}] }
      ctrl      = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: ar_fn, load_timeout: 5, poll_interval: 0,
      )
      ctrl.ensure_active("diffusiongemma")
      expect(ctrl.active_mode[:is_diffusion]).to be(false)
    end

    it "supports_reasoning:false disables <think> lift in OAI normalizer" do
      nr_status = cp_status.merge("is_diffusion" => false, "supports_reasoning" => false)
      nr_fn     = ->(_, path, _) { path == "/api/inference/status" ? [JSON.generate(nr_status), 200, {}] : ["{}", 200, {}] }
      ctrl      = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: nr_fn, load_timeout: 5, poll_interval: 0,
      )
      ctrl.ensure_active("diffusiongemma")
      mode = ctrl.active_mode

      raw        = JSON.parse(fixture("oai_ns.json"))
      normalizer = LocalInferenceProxy::OaiNormalizer.new(
        advertised_model:   "test",
        supports_reasoning: mode[:supports_reasoning],
      )
      result = normalizer.normalize(raw)
      expect(result.dig("choices", 0, "message")).not_to have_key("reasoning_content")
    end

    it "mode selection reads status fields dynamically, not a hardcoded constant" do
      [true, false].each do |diffusion_flag|
        s   = cp_status.merge("is_diffusion" => diffusion_flag)
        fn  = ->(_, path, _) { path == "/api/inference/status" ? [JSON.generate(s), 200, {}] : ["{}", 200, {}] }
        ctrl = LocalInferenceProxy::ModelController.new(
          registry: registry, cp_fn: fn, load_timeout: 5, poll_interval: 0,
        )
        ctrl.ensure_active("diffusiongemma")
        expect(ctrl.active_mode[:is_diffusion]).to eq(diffusion_flag)
      end
    end
  end

  # ── AC4: Lazy auto-swap on the `model` field ────────────────────────────────

  describe "AC4 — lazy auto-swap" do
    # cp_fn that shows qwen active initially, then diffusion after load.
    def lazy_swap_cp_fn
      load_done = false
      load_calls = []
      cp_fn = lambda do |method, path, body|
        case [method, path]
        when ["POST", "/v1/load"]
          load_calls << JSON.parse(body)
          load_done = true
          ["{}", 200, {}]
        when ["GET", "/api/inference/status"]
          load_done ? [cp_status_json, 200, {}] : [cp_status_qwen_json, 200, {}]
        when ["GET", "/v1/load-progress"]
          load_done ? [JSON.generate(cp_progress_done), 200, {}] : [cp_progress_idle_json, 200, {}]
        else
          ["{}", 200, {}]
        end
      end
      [load_calls, cp_fn]
    end

    it "POST /v1/chat/completions naming non-active alias triggers EXACTLY ONE /v1/load" do
      load_calls, cp_fn = lazy_swap_cp_fn
      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      body = JSON.generate({ model: "diffusiongemma", messages: [{ role: "user", content: "hi" }] })
      resp = call_app(test_app, "POST", "/v1/chat/completions", body)

      expect(resp.status).to eq(200)
      expect(load_calls.length).to eq(1)
      expect(load_calls.first["model_path"]).to eq("unsloth/diffusiongemma-26B-A4B-it-GGUF")
    end

    it "POST /v1/messages naming non-active alias triggers EXACTLY ONE /v1/load" do
      load_calls, cp_fn = lazy_swap_cp_fn
      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      body = JSON.generate({ model: "diffusiongemma", messages: [{ role: "user", content: "hi" }], max_tokens: 100 })
      resp = call_app(test_app, "POST", "/v1/messages", body)

      expect(resp.status).to eq(200)
      expect(load_calls.length).to eq(1)
      expect(load_calls.first["model_path"]).to eq("unsloth/diffusiongemma-26B-A4B-it-GGUF")
    end

    it "a request naming the ACTIVE alias triggers ZERO /v1/load calls" do
      load_calls, cp_fn = tracking_cp_fn(status_fn: -> { [cp_status_json, 200, {}] })
      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      body = JSON.generate({ model: "diffusiongemma", messages: [{ role: "user", content: "hi" }] })
      resp = call_app(test_app, "POST", "/v1/chat/completions", body)

      expect(resp.status).to eq(200)
      expect(load_calls).to be_empty
    end
  end

  # ── AC5: Serialized swaps + 409-busy ────────────────────────────────────────

  describe "AC5 — 409-busy and swap serialization" do
    it "(a) swap refused Failure(:busy) when generation is in flight" do
      Async do
        load_called = false
        cp_fn = lambda do |method, path, body|
          load_called = true if method == "POST" && path == "/v1/load"
          default_cp_fn.call(method, path, body)
        end
        ctrl = LocalInferenceProxy::ModelController.new(
          registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
        )

        swap_result = nil
        ctrl.with_generation do
          swap_result = ctrl.ensure_active("qwen3.6-27b")
        end

        expect(swap_result).to be_failure
        expect(swap_result.failure).to eq(:busy)
        expect(load_called).to be(false)
      end
    end

    it "(a) explicit ensure_active refused Failure(:busy) during generation (HTTP 409 from app)" do
      Async do
        ctrl = LocalInferenceProxy::ModelController.new(
          registry: registry, cp_fn: default_cp_fn, load_timeout: 5, poll_interval: 0,
        )
        swap_result = nil
        ctrl.with_generation do
          swap_result = ctrl.ensure_active("qwen3.6-27b")
        end
        expect(swap_result).to be_failure
        expect(swap_result.failure).to eq(:busy)
      end
    end

    it "(b) two concurrent swaps for SAME model: at most one /v1/load, both succeed" do
      Async do |task|
        load_done  = false
        load_calls = []

        cp_fn = lambda do |method, path, body|
          case [method, path]
          when ["POST", "/v1/load"]
            load_calls << JSON.parse(body)["model_path"]
            sleep(0) # yield so the second task can check semaphore state
            load_done = true
            ["{}", 200, {}]
          when ["GET", "/api/inference/status"]
            load_done ? [cp_status_json, 200, {}] : [cp_status_qwen_json, 200, {}]
          when ["GET", "/v1/load-progress"]
            load_done ? [JSON.generate(cp_progress_done), 200, {}] : [cp_progress_idle_json, 200, {}]
          else
            ["{}", 200, {}]
          end
        end

        ctrl = LocalInferenceProxy::ModelController.new(
          registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
        )

        t1 = task.async { ctrl.ensure_active("diffusiongemma") }
        t2 = task.async { ctrl.ensure_active("diffusiongemma") }

        r1 = t1.wait
        r2 = t2.wait

        expect([r1, r2]).to all(be_success)
        expect(load_calls.length).to eq(1)
      end
    end

    it "(c) concurrent swaps for SAME model where load never readies: awaiting caller is Failure, not false Success" do
      Async do |task|
        cp_fn = lambda do |method, path, _body|
          case [method, path]
          when ["POST", "/v1/load"]
            sleep(0) # yield so t2 observes blocking semaphore
            ["{}", 200, {}]
          when ["GET", "/api/inference/status"]
            [cp_status_qwen_json, 200, {}]
          when ["GET", "/v1/load-progress"]
            [cp_progress_idle_json, 200, {}]
          else
            ["{}", 200, {}]
          end
        end

        ctrl = LocalInferenceProxy::ModelController.new(
          registry:      registry,
          cp_fn:         cp_fn,
          load_timeout:  0,
          poll_interval: 0,
        )

        t1 = task.async { ctrl.ensure_active("diffusiongemma") }
        t2 = task.async { ctrl.ensure_active("diffusiongemma") }

        r1 = t1.wait
        r2 = t2.wait

        expect(r1).to be_failure
        expect(r2).to be_failure
      end
    end

    it "(b) concurrent swaps for DIFFERENT models: one 409s (semaphore serializes)" do
      Async do |task|
        load_done  = false
        load_calls = []

        # Neither model is active initially; after t1 loads diffusion, diffusion is active.
        cp_fn = lambda do |method, path, body|
          case [method, path]
          when ["POST", "/v1/load"]
            load_calls << JSON.parse(body)["model_path"]
            sleep(0) # yield so t2 can see blocking semaphore
            load_done = true
            ["{}", 200, {}]
          when ["GET", "/api/inference/status"]
            load_done ? [cp_status_json, 200, {}] : [cp_status_neither_json, 200, {}]
          when ["GET", "/v1/load-progress"]
            load_done ? [JSON.generate(cp_progress_done), 200, {}] : [cp_progress_idle_json, 200, {}]
          else
            ["{}", 200, {}]
          end
        end

        ctrl = LocalInferenceProxy::ModelController.new(
          registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
        )

        t1 = task.async { ctrl.ensure_active("diffusiongemma") }
        t2 = task.async { ctrl.ensure_active("qwen3.6-27b") }

        r1 = t1.wait
        r2 = t2.wait

        results = [r1, r2]
        expect(results.count(&:success?)).to eq(1)
        expect(results.count(&:failure?)).to eq(1)
        expect(results.find(&:failure?).failure).to eq(:busy)
        expect(load_calls.length).to eq(1)
      end
    end
  end

  # ── AC6: Await-readiness + timeout ──────────────────────────────────────────

  describe "AC6 — await readiness" do
    it "controller polls load-progress until fraction → 1.0 before completing" do
      poll_count = 0
      load_done  = false

      cp_fn = lambda do |method, path, _body|
        case [method, path]
        when ["POST", "/v1/load"]
          load_done = true
          ["{}", 200, {}]
        when ["GET", "/v1/load-progress"]
          poll_count += 1
          progress = if poll_count >= 3
                       cp_progress_done
                     else
                       { "phase" => "loading", "bytes_loaded" => 50,
                     "bytes_total" => 100, "fraction" => 0.5, }
                     end
          [JSON.generate(progress), 200, {}]
        when ["GET", "/api/inference/status"]
          load_done ? [cp_status_json, 200, {}] : [cp_status_qwen_json, 200, {}]
        else
          ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 10, poll_interval: 0,
      )
      result = ctrl.ensure_active("diffusiongemma")

      expect(result).to be_success
      expect(poll_count).to be >= 3
    end

    it "timeout yields a clean Failure(:timeout) — no infinite hang" do
      cp_fn = lambda do |_method, path, _body|
        case path
        when "/v1/load-progress"       then [cp_progress_idle_json, 200, {}]
        when "/api/inference/status"   then [cp_status_qwen_json, 200, {}]
        else ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 0, poll_interval: 0,
      )
      result = ctrl.ensure_active("diffusiongemma")

      expect(result).to be_failure
      expect(result.failure).to eq(:timeout)
    end

    it "timeout results in a clean 504 HTTP response from the app" do
      cp_fn = lambda do |_method, path, _body|
        case path
        when "/v1/load-progress"       then [cp_progress_idle_json, 200, {}]
        when "/api/inference/status"   then [cp_status_qwen_json, 200, {}]
        else ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 0, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      body = JSON.generate({ model: "diffusiongemma", messages: [] })
      resp = call_app(test_app, "POST", "/v1/chat/completions", body)

      expect(resp.status).to eq(504)
      expect(JSON.parse(resp.body).dig("error", "type")).to eq("upstream_error")
    end
  end

  # ── AC7: Explicit endpoint schema validation ─────────────────────────────────

  describe "AC7 — explicit endpoints" do
    it "POST /v1/load with KNOWN alias: forwards correct model_path, returns schema-valid body" do
      received_body = nil
      load_done     = false

      # Initially diffusion is active; after load, qwen becomes active.
      cp_fn = lambda do |method, path, body|
        case [method, path]
        when ["POST", "/v1/load"]
          received_body = JSON.parse(body)
          load_done     = true
          ["{}", 200, {}]
        when ["GET", "/api/inference/status"]
          load_done ? [cp_status_qwen_json, 200, {}] : [cp_status_json, 200, {}]
        when ["GET", "/v1/load-progress"]
          load_done ? [JSON.generate(cp_progress_done), 200, {}] : [cp_progress_idle_json, 200, {}]
        else ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      resp = call_app(test_app, "POST", "/v1/load", JSON.generate({ "model" => "qwen3.6-27b" }))

      expect(resp.status).to eq(200)
      expect(received_body["model_path"]).to eq("unsloth/Qwen3.6-27B-MTP-GGUF")
      result = LocalInferenceProxy::Schemas::LOAD_RESPONSE.call(JSON.parse(resp.body))
      expect(result).to be_success
    end

    it "POST /v1/load with UNKNOWN alias returns clean 4xx" do
      post "/v1/load", JSON.generate({ "model" => "no-such-alias" }), "CONTENT_TYPE" => "application/json"
      expect(last_response.status).to be_between(400, 499)
      expect(JSON.parse(last_response.body).dig("error", "message")).to be_a(String)
    end

    it "POST /v1/load forwards gguf_variant from alias config" do
      received_body = nil
      load_done     = false

      # Initially qwen is active; after load, diffusion becomes active.
      cp_fn = lambda do |method, path, body|
        case [method, path]
        when ["POST", "/v1/load"]
          received_body = JSON.parse(body)
          load_done     = true
          ["{}", 200, {}]
        when ["GET", "/api/inference/status"]
          load_done ? [cp_status_json, 200, {}] : [cp_status_qwen_json, 200, {}]
        when ["GET", "/v1/load-progress"]
          load_done ? [JSON.generate(cp_progress_done), 200, {}] : [cp_progress_idle_json, 200, {}]
        else ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      call_app(test_app, "POST", "/v1/load", JSON.generate({ "model" => "diffusiongemma" }))
      expect(received_body["gguf_variant"]).to eq("Q8_0")
    end

    it "POST /v1/unload forwards model_path upstream, returns schema-valid body" do
      received_unload = nil
      cp_fn = lambda do |method, path, body|
        if method == "POST" && path == "/v1/unload"
          received_unload = JSON.parse(body)
          [JSON.generate({ "status" => "ok" }), 200, {}]
        else
          ["{}", 200, {}]
        end
      end

      ctrl = LocalInferenceProxy::ModelController.new(
        registry: registry, cp_fn: cp_fn, load_timeout: 5, poll_interval: 0,
      )
      test_app = LocalInferenceProxy::App.new(upstream_fn: upstream_fn, controller: ctrl)

      resp = call_app(test_app, "POST", "/v1/unload",
                      JSON.generate({ "model_path" => "unsloth/diffusiongemma-26B-A4B-it-GGUF" }),)

      expect(resp.status).to eq(200)
      expect(received_unload["model_path"]).to eq("unsloth/diffusiongemma-26B-A4B-it-GGUF")
      result = LocalInferenceProxy::Schemas::UNLOAD_RESPONSE.call(JSON.parse(resp.body))
      expect(result).to be_success
    end

    it "GET /v1/load-progress returns schema-valid shape" do
      get "/v1/load-progress"
      expect(last_response.status).to eq(200)
      result = LocalInferenceProxy::Schemas::LOAD_PROGRESS.call(JSON.parse(last_response.body))
      expect(result).to be_success
    end
  end
end
