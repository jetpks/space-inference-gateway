# frozen_string_literal: true

require "dry-schema"

module SpaceInferenceGateway
  module Schemas # rubocop:disable Metrics/ModuleLength
    # OpenAI non-stream chat.completion
    OAI_COMPLETION = Dry::Schema.JSON do # rubocop:disable Metrics/BlockLength
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
          optional(:tool_calls).array(:hash) do
            required(:id).filled(:string)
            required(:type).filled(:string)
            required(:function).hash do
              required(:name).filled(:string)
              required(:arguments).filled(:string)
            end
          end
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
          optional(:tool_calls).array(:hash) do
            required(:index).filled(:integer)
            optional(:id).maybe(:string)
            optional(:type).maybe(:string)
            optional(:function).hash do
              optional(:name).maybe(:string)
              optional(:arguments).maybe(:string)
            end
          end
        end
        optional(:finish_reason).maybe(:string)
      end
    end

    # Anthropic non-stream message
    ANT_MESSAGE = Dry::Schema.JSON do # rubocop:disable Metrics/BlockLength
      config.validate_keys = true

      required(:id).filled(:string)
      required(:type).value(eql?: "message")
      required(:role).value(eql?: "assistant")
      required(:content).array(:hash) do
        required(:type).filled(:string)
        optional(:text).maybe(:string)
        optional(:thinking).maybe(:string)
        optional(:id).maybe(:string)
        optional(:name).maybe(:string)
        optional(:input)
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

      # tool_use `input` is user-defined: strip it before key validation so
      # validate_keys does not reject arbitrary argument keys.
      before(:key_validator) do |result|
        h = result.to_h
        next result unless h["content"].is_a?(Array)

        stripped = h["content"].map { |b| b.key?("input") ? b.except("input") : b }
        result.update("content" => stripped)
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
  end
end
