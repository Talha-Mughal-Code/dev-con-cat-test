module Engine
  module Evaluators
    # Two independent email providers. Both agreeing undeliverable is a strong
    # signal; a split is the textbook REVIEW candidate.
    #
    # Note that several conditions can fire at once here - the fixture's bot
    # lead is undeliverable AND disposable AND high fraud score. Consensus takes
    # the MAXIMUM of a layer's contributions rather than summing them, because
    # those are three correlated observations from one source, not three
    # independent voices.
    class EmailValidation < Base
      # Above this, a provider is telling us the address itself looks like fraud
      # rather than merely being undeliverable.
      ELEVATED_FRAUD_SCORE = 50

      def self.module_key = "email_validation"

      def call(payload, _context)
        providers = payload["providers"]&.except("_note") || {}
        return assessment(summary: "No email provider responses", breakdown: payload) if providers.empty?

        deliverable = providers.select { |_, r| truthy?(r["deliverable"]) }
        undeliverable = providers.reject { |_, r| truthy?(r["deliverable"]) }
        disposable = providers.select { |_, r| truthy?(r["disposable"]) }
        scores = providers.values.filter_map { |r| r["fraud_score"] }
        mean_score = scores.any? ? (scores.sum.to_f / scores.size).round(1) : nil

        findings = []

        if undeliverable.size == providers.size
          findings << finding(
            weight_key: "consensus_undeliverable",
            detail: "All #{providers.size} providers agree the mailbox is undeliverable"
          )
        elsif undeliverable.any?
          findings << finding(
            weight_key: "providers_disagree",
            detail: "Providers disagree on deliverability: " \
                    "#{deliverable.keys.join(', ')} vs #{undeliverable.keys.join(', ')}"
          )
        end

        if disposable.any?
          findings << finding(
            weight_key: "disposable",
            detail: "#{disposable.keys.join(' and ')} flag the domain as disposable/throwaway"
          )
        end

        if mean_score && mean_score >= ELEVATED_FRAUD_SCORE
          findings << finding(weight_key: "elevated_fraud_score",
                              detail: "Mean provider fraud score #{mean_score}/100")
        end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "#{deliverable.size}/#{providers.size} providers agree the mailbox is deliverable" \
                   "#{mean_score ? " (fraud score #{mean_score})" : ''}",
          breakdown: {
            "providers" => providers,
            "agreement" => {
              "deliverable" => deliverable.keys, "undeliverable" => undeliverable.keys,
              "disposable" => disposable.keys, "mean_fraud_score" => mean_score,
              "unanimous" => undeliverable.empty? || undeliverable.size == providers.size
            }
          }
        )
      end
    end
  end
end
