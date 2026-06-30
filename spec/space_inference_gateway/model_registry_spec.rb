# frozen_string_literal: true

require "spec_helper"
require "space_inference_gateway/model_registry"

RSpec.describe SpaceInferenceGateway::ModelRegistry do
  def registry_for(gguf:, binary:)
    described_class.new(
      "default" => "m",
      "models"  => { "m" => { "gguf" => gguf, "binary" => binary, "port" => 8080 } },
    )
  end

  it "expands a leading ~ in gguf and binary paths to HOME" do
    entry = registry_for(gguf: "~/models/x.gguf", binary: "~/llama.cpp/llama-server").resolve("m")

    expect(entry[:gguf]).to   eq(File.join(Dir.home, "models/x.gguf"))
    expect(entry[:binary]).to eq(File.join(Dir.home, "llama.cpp/llama-server"))
  end

  it "leaves already-absolute paths unchanged" do
    entry = registry_for(gguf: "/abs/x.gguf", binary: "/abs/llama-server").resolve("m")

    expect(entry[:gguf]).to   eq("/abs/x.gguf")
    expect(entry[:binary]).to eq("/abs/llama-server")
  end
end
