# frozen_string_literal: true

require "space_inference_gateway"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.warnings = true
  config.order = :random
end

FIXTURE_PATH = File.expand_path("fixtures/unsloth", __dir__)
LLAMACPP_FIXTURE_PATH = File.expand_path("fixtures/llamacpp", __dir__)
SYNTHETIC_FIXTURE_PATH = File.expand_path("fixtures/synthetic", __dir__)

def fixture(name)
  File.read(File.join(FIXTURE_PATH, name))
end

def fixture_json(name)
  JSON.parse(fixture(name))
end

def llamacpp_fixture(name)
  File.read(File.join(LLAMACPP_FIXTURE_PATH, name))
end

def llamacpp_fixture_json(name)
  JSON.parse(llamacpp_fixture(name))
end

def synthetic_fixture(name)
  File.read(File.join(SYNTHETIC_FIXTURE_PATH, name))
end
