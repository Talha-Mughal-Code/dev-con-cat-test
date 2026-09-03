module Engine
  # One observation an evaluator made about one lead.
  #
  # A finding is deliberately POLICY-FREE: it records what the vendor said in our
  # vocabulary and stops there. Whether `hard_stop_code` actually disposes of the
  # lead, and what a `weight_key` is worth, are decided later by Consensus
  # against the active policy.
  #
  # That seam is the point. Evaluators know vendor semantics and nothing about
  # thresholds; Consensus knows thresholds and nothing about vendors. Adding a
  # twelfth vendor is a new evaluator; changing how strictly the platform judges
  # touches neither.
  Finding = Struct.new(
    :module_key,
    :hard_stop_code,  # a code from HardStops::CODES, when this observation could be dispositive
    :weight_key,      # key into the policy's weights for this module
    :detail,          # human-readable, shown in the UI and written to the certificate
    :advisory,        # commercial flag rather than a fraud signal (see soft duplicates)
    keyword_init: true
  ) do
    def dispositive_candidate? = hard_stop_code.present?

    def advisory? = !!advisory
  end
end
