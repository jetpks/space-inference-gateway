# frozen_string_literal: true

require "dry-schema"

module LocalInferenceProxy
  module Schemas
    # OpenAI non-stream chat.completion
    OAI_COMPLETION = Dry::Schema.JSON do
      config.validate_keys = true

      required(:id).filled(:string)
      required(:object).filled(:string)
      required(:created).filled(:integer)
      required(:model).filled(:string)
      required(:choices).array(:hash) do
        required(:index).filled(:integer)
        required(:message).hash do
          required(:role).filled(:string)
          required(:content).maybe(:string)
          optional(:reasoning_content).maybe(:string)
          optional(:refusal).maybe(:string)
        end
        required(:finish_reason).maybe(:string)
        optional(:logprobs)
      end
      required(:usage).hash do
        required(:prompt_tokens).filled(:integer)
        required(:completion_tokens).filled(:integer)
        required(:total_tokens).filled(:integer)
      end
      optional(:system_fingerprint).maybe(:string)
    end

    # OpenAI streaming chat.completion.chunk
    OAI_CHUNK = Dry::Schema.JSON do
      config.validate_keys = true

      required(:id).filled(:string)
      required(:object).value(eql?: "chat.completion.chunk")
      required(:created).filled(:integer)
      required(:model).filled(:string)
      required(:choices).array(:hash) do
        required(:index).filled(:integer)
        required(:delta).hash do
          optional(:role).maybe(:string)
          optional(:content).maybe(:string)
          optional(:reasoning_content).maybe(:string)
          optional(:refusal).maybe(:string)
        end
        optional(:finish_reason).maybe(:string)
      end
    end

    # Anthropic non-stream message
    ANT_MESSAGE = Dry::Schema.JSON do
      config.validate_keys = true

      required(:id).filled(:string)
      required(:type).value(eql?: "message")
      required(:role).value(eql?: "assistant")
      required(:content).array(:hash) do
        required(:type).filled(:string)
        optional(:text).maybe(:string)
        optional(:thinking).maybe(:string)
      end
      required(:model).filled(:string)
      required(:stop_reason).maybe(:string)
      optional(:stop_sequence).maybe(:string)
      required(:usage).hash do
        required(:input_tokens).filled(:integer)
        required(:output_tokens).filled(:integer)
        optional(:cache_creation_input_tokens).maybe(:integer)
        optional(:cache_read_input_tokens).maybe(:integer)
      end
    end

    DIFFUSION_BANNED_KEYS = %w[type block step total text].freeze

    # GET /v1/models response
    MODELS_LIST = Dry::Schema.JSON do
      config.validate_keys = true

      required(:object).value(eql?: "list")
      required(:data).array(:hash) do
        required(:id).filled(:string)
        required(:object).filled(:string)
        required(:created).filled(:integer)
        required(:owned_by).filled(:string)
      end
    end

    # GET /v1/load-progress response (proxied from upstream)
    LOAD_PROGRESS = Dry::Schema.JSON do
      config.validate_keys = true

      required(:phase).maybe(:string)
      required(:bytes_loaded).filled(:integer)
      required(:bytes_total).filled(:integer)
      required(:fraction).filled(:float)
    end

    # POST /v1/load response (synthesized after readiness poll)
    LOAD_RESPONSE = Dry::Schema.JSON do
      config.validate_keys = true

      required(:status).filled(:string)
      required(:model_path).filled(:string)
    end

    # POST /v1/unload response (synthesized)
    UNLOAD_RESPONSE = Dry::Schema.JSON do
      config.validate_keys = true

      required(:status).filled(:string)
      required(:model_path).filled(:string)
    end

    # Error body for 4xx / 5xx control-plane responses
    CP_ERROR = Dry::Schema.JSON do
      config.validate_keys = true

      required(:error).hash do
        required(:message).filled(:string)
        required(:type).filled(:string)
      end
    end
  end
end
