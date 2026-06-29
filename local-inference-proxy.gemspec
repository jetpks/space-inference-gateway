# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require_relative "lib/local_inference_proxy/version"

Gem::Specification.new do |spec|
  spec.name          = "local-inference-proxy"
  spec.version       = LocalInferenceProxy::VERSION
  spec.authors       = ["eric"]
  spec.summary       = "Falcon normalization proxy for local unsloth inference (OpenAI + Anthropic flavors)"
  spec.executables   = ["local-inference-proxy"]

  spec.required_ruby_version = ">= 3.3"

  spec.add_dependency "async",         "~> 2.0"
  spec.add_dependency "async-http",    "~> 0.75"
  spec.add_dependency "async-process", "~> 1.1"
  spec.add_dependency "dry-monads",  "~> 1.10"
  spec.add_dependency "dry-schema",  "~> 1.16"
  spec.add_dependency "falcon",      "~> 0.55"

  spec.files         = Dir.glob("lib/**/*.rb") + %w[Gemfile config.ru]
  spec.require_paths = ["lib"]
  spec.metadata["rubygems_mfa_required"] = "true"
end
