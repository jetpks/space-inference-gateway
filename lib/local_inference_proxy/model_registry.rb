# frozen_string_literal: true

require "yaml"

module LocalInferenceProxy
  class ModelRegistry
    DEFAULT_CONFIG_PATH = File.expand_path("../../config/models.yml", __dir__)

    def self.load(path: ENV.fetch("MODEL_CONFIG_PATH", DEFAULT_CONFIG_PATH))
      raw = YAML.safe_load_file(path, symbolize_names: false)
      new(raw)
    end

    def initialize(config)
      @default = config["default"]
      @models  = (config["models"] || {}).transform_values do |v|
        v.transform_keys(&:to_sym)
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
