module Engine
  # What the pipeline hands Consensus for each layer: the state it reached, and
  # - only if it actually ran - the assessment its evaluator produced.
  #
  # fail_closed travels with the outcome rather than being looked up, because
  # the engine must not query the database. It is the flag that decides whether a
  # layer which could not answer caps the verdict at REVIEW or is simply scored
  # around.
  LayerOutcome = Struct.new(:module_key, :state, :assessment, :fail_closed,
                            keyword_init: true) do
    ANSWERED = "completed"
    # Never spoke, and no evidence is missing as a result: the buyer did not pay
    # for it, it does not apply to this lead, or the lead was already
    # dispositively rejected so we chose not to spend credits on it. Excluded
    # from coverage, and each reported by name.
    SILENT_STATES = %w[not_enabled not_applicable skipped_hard_stop].freeze
    # Should have spoken and did not. Counts against coverage, and triggers
    # fail-closed handling for the layers that declare it.
    MISSING_STATES = %w[errored timed_out skipped_insufficient_credits pending].freeze

    def answered?  = state == ANSWERED
    def silent?    = SILENT_STATES.include?(state)
    def missing?   = MISSING_STATES.include?(state)
    def expected?  = !silent?
    def fail_closed? = !!fail_closed

    def findings = answered? ? Array(assessment&.findings) : []
  end
end
