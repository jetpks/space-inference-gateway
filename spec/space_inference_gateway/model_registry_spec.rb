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

  def registry_with_penalties(penalties)
    described_class.new(
      "default" => "m",
      "models"  => { "m" => { "model" => "x", "port" => 8080, "penalties" => penalties } },
    )
  end

  it "keeps a declared penalties mapping on the entry" do
    entry = registry_with_penalties("repetition_penalty" => 1.05, "repetition_context_size" => 64).resolve("m")

    expect(entry[:penalties]).to eq("repetition_penalty" => 1.05, "repetition_context_size" => 64)
  end

  it "accepts every penalty the engine documents" do
    all = SpaceInferenceGateway::MlxVlmFlags::REQUEST_PENALTIES.to_h { |k| [k, 1] }

    expect { registry_with_penalties(all) }.not_to raise_error
  end

  # A key the engine ignores would read as a tuned knob and do nothing.
  it "refuses an unknown penalty key at load, naming it" do
    expect { registry_with_penalties("repitition_penalty" => 1.05) }
      .to raise_error(ArgumentError, /unknown penalties key\(s\): repitition_penalty/)
  end

  it "refuses a penalties value that is not a mapping" do
    expect { registry_with_penalties(1.05) }.to raise_error(ArgumentError, /must be a mapping/)
  end

  it "leaves an entry without penalties untouched" do
    entry = described_class.new(
      "default" => "m", "models" => { "m" => { "model" => "x", "port" => 8080 } },
    ).resolve("m")

    expect(entry).not_to have_key(:penalties)
  end
end
