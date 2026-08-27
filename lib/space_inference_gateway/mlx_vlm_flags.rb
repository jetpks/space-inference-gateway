# frozen_string_literal: true

module SpaceInferenceGateway
  # The mlx-vlm engine's CLI vocabulary, kept apart from process supervision:
  # InferenceServerSupervisor owns the child's lifecycle, this owns what the
  # child is told. Adding a knob is a data change here, not a code change there.
  module MlxVlmFlags
    # Registry key → mlx_vlm.server CLI flag, for scalar values passed through
    # verbatim. These are the memory- and context-shaping knobs: on a machine
    # where the weights already occupy most of the wired limit, --max-kv-size
    # and the --kv-*-bits family are what keep a long-context alias inside its
    # budget instead of letting the cache grow until the box swaps.
    #
    # Deliberately absent: apc_*, thinking_budget and max_num_seqs are
    # environment-only on mlx-vlm (see .env_for below), and
    # draft_model/draft_kind are emitted by the caller ahead of these to
    # preserve the argv order those flags already had.
    TUNING = {
      max_tokens:           "--max-tokens",
      prefill_step_size:    "--prefill-step-size",
      vision_cache_size:    "--vision-cache-size",
      max_kv_size:          "--max-kv-size",
      kv_bits:              "--kv-bits",
      kv_key_bits:          "--kv-key-bits",
      kv_value_bits:        "--kv-value-bits",
      kv_quant_scheme:      "--kv-quant-scheme",
      kv_key_scheme:        "--kv-key-scheme",
      kv_value_scheme:      "--kv-value-scheme",
      kv_group_size:        "--kv-group-size",
      quantized_kv_start:   "--quantized-kv-start",
      draft_block_size:     "--draft-block-size",
      thinking_start_token: "--thinking-start-token",
      thinking_end_token:   "--thinking-end-token",
    }.freeze

    # Registry key → environment variable, for the knobs mlx-vlm exposes no
    # CLI flag for. APC_ENABLED is a presence flag rather than a value, so it
    # is built by hand; the rest are straight stringifications. Keys the entry
    # does not declare are compacted away, leaving the child's environment
    # untouched.
    def self.env_for(entry)
      { "APC_ENABLED" => (entry[:apc_enabled] ? "1" : nil),
        "APC_EXACT_CACHE_ENTRIES" => entry[:apc_exact_cache_entries]&.to_s,
        "MLX_VLM_THINKING_BUDGET" => entry[:thinking_budget]&.to_s,
        "MLX_VLM_MAX_NUM_SEQS" => entry[:max_num_seqs]&.to_s,
        "MLX_VLM_TOKEN_QUEUE_TIMEOUT" => entry[:token_queue_timeout]&.to_s, }.compact
    end

    # Emitted in TUNING order so a given entry always renders the same argv.
    # Rejects on nil? rather than truthiness: quantized_kv_start: 0 is a
    # meaningful value, and `if entry[key]` would silently drop it.
    def self.tuning_argv(entry)
      TUNING.filter_map { |key, flag| [flag, entry[key].to_s] unless entry[key].nil? }.flatten
    end
  end
end
