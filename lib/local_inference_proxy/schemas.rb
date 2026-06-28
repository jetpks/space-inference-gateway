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
  end
end
