# frozen_string_literal: true

require "yaml"

module SpaceInferenceGateway
  class ModelRegistry
    DEFAULT_CONFIG_PATH = File.expand_path("../../config/models.yml", __dir__)

    def self.load(path: ENV.fetch("MODEL_CONFIG_PATH", DEFAULT_CONFIG_PATH))
      raw = YAML.safe_load_file(path, symbolize_names: false)
      new(raw)
    end

    # Path-valued entry keys get `~` expanded (and made absolute) so config can
    # use `~/...` — argv goes straight to exec, which never expands a shell `~`.
    # `model` is NOT a path key: it is the HF repo id (or local path) mlx_lm.server
    # loads via --model, and must be passed through verbatim (no ~ expansion).
    PATH_KEYS = %i[venv gguf binary].freeze

    def initialize(config)
      @default = config["default"]
      @models  = (config["models"] || {}).transform_values do |v|
        entry = v.transform_keys(&:to_sym)
        PATH_KEYS.each { |k| entry[k] = File.expand_path(entry[k]) if entry[k] }
        entry
      end
    end

    # Returns the entry Hash for alias_name, or nil if unknown.
    # Callers that need a Result monad should map nil → Failure(:unknown_model).
    def resolve(alias_name)
      @models[alias_name]
    end

    def default_alias
      @default
    end

    def aliases
      @models.keys
    end
  end
end
