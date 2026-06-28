# frozen_string_literal: true

lib = File.expand_path("lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "local-inference-proxy"
  spec.version       = "0.1.0"
  spec.authors       = ["eric"]
  spec.summary       = "Loopback->LAN TCP forwarder for local inference runners"
  spec.executables   = ["local-inference-proxy"]

  spec.required_ruby_version = ">= 3.0"

  spec.add_dependency "async", "~> 2.0"

  spec.files         = Dir.glob("lib/**/*.rb") + %w[Gemfile]
  spec.require_paths = ["lib"]
end
