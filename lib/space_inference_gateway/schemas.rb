# frozen_string_literal: true

require "dry-schema"

module SpaceInferenceGateway
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

    # Anthropic non-stream message.
    #
    # A tool_use content block's "input" is the model's tool-call arguments —
    # an arbitrary JSON object shape defined by whatever tool the client sent,
    # not something this schema can enumerate. Dry::Schema's config.validate_keys
    # recurses into every nested hash it finds, so turning it on here would
    # reject any non-empty "input" (verified against dry-schema 1.16.0's
    # KeyValidator, which walks actual hash values regardless of how they're
    # typed in the schema). AntMessageValidator checks the fixed shape with
    # dry-schema, then rejects unexpected keys by hand at every level except
    # "input"'s contents, which are intentionally left unvalidated.
    class AntMessageValidator
      SHAPE = Dry::Schema.JSON do
        required(:id).filled(:string)
        required(:type).value(eql?: "message")
        required(:role).value(eql?: "assistant")
        required(:content).array(:hash) do
          required(:type).filled(:string)
          optional(:text).maybe(:string)
          optional(:thinking).maybe(:string)
          optional(:id).maybe(:string)
          optional(:name).maybe(:string)
          optional(:input).maybe(:hash)
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

      TOP_KEYS   = %w[id type role content model stop_reason stop_sequence usage].freeze
      BLOCK_KEYS = %w[type text thinking id name input].freeze
      USAGE_KEYS = %w[input_tokens output_tokens cache_creation_input_tokens cache_read_input_tokens].freeze

      def self.call(payload)
        result = SHAPE.call(payload)
        return result unless payload.is_a?(Hash)

        reject_extra_keys(result, payload, TOP_KEYS)
        Array(payload["content"]).each_with_index do |block, i|
          reject_extra_keys(result, block, BLOCK_KEYS, [:content, i]) if block.is_a?(Hash)
        end
        reject_extra_keys(result, payload["usage"], USAGE_KEYS, [:usage]) if payload["usage"].is_a?(Hash)
        result
      end

      def self.reject_extra_keys(result, hash, allowed, path_prefix = [])
        (hash.keys.map(&:to_s) - allowed).each do |key|
          path = path_prefix.empty? ? key : [*path_prefix, key.to_sym]
          result.add_error([:unexpected_key, [path, hash]])
        end
      end
      private_class_method :reject_extra_keys
    end

    ANT_MESSAGE = AntMessageValidator

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
