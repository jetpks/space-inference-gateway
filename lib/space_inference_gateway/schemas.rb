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
    #
    # No config.validate_keys: dry-schema's key_validator derives key paths from the
    # *input data*, recursing unconditionally into every nested ::Hash regardless of
    # how it's declared (dry-schema key_validator.rb key_paths, ~L66-84), and
    # config.validate_keys is a single per-schema toggle with no per-path exemption
    # (dry-schema dsl.rb:200). tool_use `input` is user-defined and arbitrarily nested,
    # so validate_keys would reject it no matter how it's declared. A strip-before/
    # restore-after key_validator hook was tried (I01) but Result#update mutates the
    # shared result in place (dry-schema result.rb:60-63) and Result has no per-call
    # scratch space, so restoring requires stashing data in schema-level state shared
    # across concurrent calls — correctness would depend on no fiber yielding between
    # the two hooks, an unenforced invariant. Dropped validate_keys instead; required
    # fields are still enforced independently by the rule applier.
    ANT_MESSAGE = Dry::Schema.JSON do
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
