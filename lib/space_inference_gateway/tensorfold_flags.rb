# frozen_string_literal: true

module SpaceInferenceGateway
  # The tensorfold engine's CLI vocabulary, kept apart from process
  # supervision — the same seam as MlxVlmFlags: the supervisor owns the
  # child's lifecycle, this owns what the child is told. TensorFold
  # (brew: ashhart/tensorfold/tensorfold) is a Zig inference engine serving
  # MLX-format checkpoints straight from the Hugging Face cache — OpenAI
  # wire and GET /health natively, one model per process, advertised under
  # --name. It therefore slots into the same single-flight hot-swap as the
  # other engines with no translation layer of its own.
  module TensorfoldFlags
    # Registry keys with no tensorfold equivalent. Every one would be a
    # silently-dropped knob on a tensorfold alias: the apc_* family is
    # mlx-vlm's prompt cache (tensorfold's analogue is --prompt-cache-gib,
    # deliberately not mapped — different mechanism, GiB-budget not
    # slot-count), mtp/mtp_depth/max_concurrent are optiq's, decode_/
    # prompt_concurrency are mlx_lm's, draft_kind is implicit (a drafter is
    # MTP by construction here), and trust_remote_code has no tensorfold
    # meaning. The registry rejects them at load time, naming the offenders.
    UNSUPPORTED_KEYS = %i[
      apc_enabled apc_disk_cache apc_checkpoint_entries apc_checkpoint_interval_tokens
      apc_checkpoint_guard_tokens apc_block_size apc_num_blocks apc_memory_max_gb
      apc_memory_reserve_gb apc_disk_path apc_disk_max_gb apc_disk_queue_max_gb
      apc_disk_shard_max_blocks apc_exact_cache_entries
      decode_concurrency prompt_concurrency prompt_cache_size
      mtp mtp_depth max_concurrent draft_kind trust_remote_code
    ].freeze

    # Registry key → tensorfold serve CLI flag, scalar passthrough in this
    # order. max_num_seqs → --parallel carries the same scheduler-width
    # meaning it has on mlx-vlm (active request cap; tensorfold's default
    # `auto` asks for up to 8 streams — declare 1 to hold the single-stream
    # operating point). draft_model → --drafter names a repo id or directory.
    # context and max_tokens bound prompt+reply and the default reply limit.
    #
    # enable_thinking is NOT here: it maps both ways (--thinking /
    # --no-thinking) around an absent-key third state, so the supervisor
    # builds it by hand ahead of this tail.
    TUNING = {
      thinking_budget:  "--thinking-budget",
      reasoning_effort: "--reasoning-effort",
      max_tokens:       "--max-tokens",
      context:          "--context",
      max_num_seqs:     "--parallel",
      draft_model:      "--drafter",
    }.freeze

    # Raises naming every unsupported key the entry declares. Called by the
    # registry at load (config honesty: a key that reads as a tuned knob but
    # does nothing must fail loudly, not serve) and re-checked by the
    # supervisor's builder, which also sees raw entry hashes.
    def self.validate!(entry)
      unsupported = UNSUPPORTED_KEYS & entry.keys
      return if unsupported.empty?

      raise ArgumentError,
            "tensorfold engine does not accept: #{unsupported.join(", ")} " \
            "(mlx-vlm/optiq/mlx-only keys — remove them; tensorfold would silently drop them)"
    end

    # Emitted in TUNING order so a given entry always renders the same argv.
    def self.tuning_argv(entry)
      TUNING.filter_map { |key, flag| [flag, entry[key].to_s] unless entry[key].nil? }.flatten
    end

    # The full `tensorfold serve` argv for a registry entry. Lives here, not
    # in the supervisor, so all of this engine's vocabulary is in one place —
    # the supervisor's seam stays the one-line dispatch (its class is at its
    # length budget, and this is data about an engine, not supervision).
    #
    # --name is load-bearing: the app layer forwards the gateway alias as
    # the request's model field unrewritten (rewrite_model_for_mlx rewrites
    # only mlx/mlx-vlm), and the server answers only for names it serves,
    # so the served name must be the registry key itself. enable_thinking
    # maps both ways around an absent-key third state — the chat template's
    # own default, which varies per checkpoint and must stay expressible.
    def self.serve_argv(entry, alias_name)
      validate!(entry)

      argv = [entry[:venv].to_s, "serve", entry[:model].to_s,
              "--host", "127.0.0.1", "--port", entry[:port].to_s,]
      argv += ["--name", alias_name.to_s]
      argv << "--thinking" if entry[:enable_thinking]
      argv << "--no-thinking" if entry[:enable_thinking] == false
      argv += tuning_argv(entry)
      argv += Array(entry[:extra_args])
      argv
    end
  end
end
