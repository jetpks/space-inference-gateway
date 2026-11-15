# frozen_string_literal: true

require "dry-schema"

module SpaceInferenceGateway
  module Schemas
    # Token usage — shared by the non-stream completion and the forwarded
    # terminal stream chunk (stream_options.include_usage).
    USAGE = Dry::Schema.JSON do
      config.validate_keys = true

      required(:prompt_tokens).filled(:integer)
      required(:completion_tokens).filled(:integer)
      required(:total_tokens).filled(:integer)
    end

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
      required(:usage).value(USAGE)
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
          # Streaming tool-call deltas — relayed verbatim, complete or fragment.
          optional(:tool_calls).array(:hash) do
            optional(:type).maybe(:string)
            optional(:index).maybe(:integer)
            optional(:id).maybe(:string)
            optional(:function).hash do
              optional(:name).maybe(:string)
              optional(:arguments).maybe(:string)
            end
          end
        end
        optional(:finish_reason).maybe(:string)
      end
      # Terminal usage (stream_options.include_usage): upstream sends it on a
      # final choices:[] chunk; the normalizer forwards it sanitized (USAGE).
      optional(:usage).value(USAGE)
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
