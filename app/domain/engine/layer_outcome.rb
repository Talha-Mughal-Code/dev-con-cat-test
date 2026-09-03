module Engine
  # What the pipeline hands Consensus for each layer: the state it reached, and
  # - only if it actually ran - the assessment its evaluator produced.
  #
  # consent_critical travels with the outcome rather than being looked up,
  # because the engine must not query the database. It is the flag that decides
  # fail-closed vs fail-open when a layer could not answer.
  LayerOutcome = Struct.new(:module_key, :state, :assessment, :consent_critical,
                            keyword_init: true) do
    ANSWERED = "completed"
    # Never spoke, and that is nobody's failure: the buyer did not pay for it, or
    # it does not apply to this lead. Excluded from coverage entirely.
    SILENT_STATES = %w[not_enabled not_applicable].freeze
    # Should have spoken and did not. Counts against coverage, and triggers
    # fail-closed handling for consent-critical layers.
    MISSING_STATES = %w[errored timed_out skipped_insufficient_credits pending].freeze

    def answered?  = state == ANSWERED
    def silent?    = SILENT_STATES.include?(state)
    def missing?   = MISSING_STATES.include?(state)
    def expected?  = !silent?
    def consent_critical? = !!consent_critical

    def findings = answered? ? Array(assessment&.findings) : []
  end
end
