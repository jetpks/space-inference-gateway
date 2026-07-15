# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative "lib/space_inference_gateway/version"

Gem::Specification.new do |spec|
  spec.name          = "space-inference-gateway"
  spec.version       = SpaceInferenceGateway::VERSION
  spec.authors       = ["eric"]
  spec.summary       = "Falcon gateway for local llama.cpp inference: supervises llama-server, " \
                       "swaps models, and normalizes OpenAI + Anthropic flavors"
  spec.executables   = ["space-inference-gateway"]

  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "async",         "~> 2.0"
  spec.add_dependency "async-http",    "~> 0.75"
  spec.add_dependency "async-process", "~> 1.1"
  spec.add_dependency "dry-monads",  "~> 1.10"
  spec.add_dependency "dry-schema",  "~> 1.16"
  spec.add_dependency "falcon",      "~> 0.55"
  spec.add_dependency "prometheus-client", "~> 4.2"

  spec.files         = Dir.glob("lib/**/*.rb") + %w[Gemfile config.ru]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
