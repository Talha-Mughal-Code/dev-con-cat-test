module Engine
  module Evaluators
    # Voice-actor and synthetic-voice detection for leads captured with a voice
    # step.
    #
    # This is the layer the brief uses to make its point about applicability:
    # most leads have no voice sample, and "no sample" is emphatically not a
    # pass. `applicable?` returning false makes the pipeline record
    # state = not_applicable, which scores nothing, costs nothing, and appears on
    # the certificate as N/A rather than as a check that passed.
    class Voice < Base
      FRAUD_VERDICTS = %w[human_reused_actor synthetic].freeze

      def self.module_key = "voice"

      def applicable?(payload, _context)
        payload.present? && payload["has_sample"] == true
      end

      def call(payload, _context)
        verdict = payload["verdict"].to_s
        prior = Array(payload["matched_prior_leads"])

        findings =
          if FRAUD_VERDICTS.include?(verdict)
            [ finding(hard_stop_code: "voice_fraud", weight_key: "fraud",
                      detail: fraud_detail(verdict, prior, payload)) ]
          else
            []
          end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "Voiceprint is a unique human sample (#{payload['voiceprint_id']})",
          breakdown: payload.slice("has_sample", "verdict", "voiceprint_id",
                                   "matched_prior_leads", "notes")
        )
      end

      private

      def fraud_detail(verdict, prior, payload)
        if verdict == "synthetic"
          "Synthetic/AI-generated voice detected (#{payload['voiceprint_id']})"
        else
          "Voice-actor fraud: voiceprint #{payload['voiceprint_id']} already submitted under " \
            "#{prior.size} other #{'identity'.pluralize(prior.size)}" \
            "#{prior.any? ? " (#{prior.join(', ')})" : ''}"
        end
      end
    end
  end
end
