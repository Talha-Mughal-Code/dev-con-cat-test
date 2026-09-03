module Engine
  module Evaluators
    # Bot, malware and human-fraud-farm detection.
    #
    # The split here is the one the brief insists on: 'bad' is a determination
    # (explicit rule ids, high confidence) and disposes of the lead; 'suspect'
    # is a suspicion and must not auto-kill a lead on its own.
    class Anura < Base
      def self.module_key = "anura"

      def call(payload, _context)
        result = payload["result"].to_s
        rules = Array(payload["rule_ids"])
        traffic = payload["invalid_traffic_type"].to_s
        confidence = payload["confidence"]

        findings =
          case result
          when "bad"
            [ finding(hard_stop_code: "bot_confirmed", weight_key: "confirmed_bad",
                      detail: "Confirmed invalid traffic (#{traffic.presence || 'bot'})" \
                              "#{rules.any? ? ": #{rules.join(', ')}" : ''}") ]
          when "suspect"
            # A fraud farm is organised, repeat abuse rather than a one-off
            # oddity, so it is weighted above a bare suspicion.
            if traffic == "human_fraud_farm"
              [ finding(weight_key: "suspect_fraud_farm",
                        detail: "Suspected human fraud farm: #{rules.join(', ').presence || 'clustered activity'}") ]
            else
              [ finding(weight_key: "suspect",
                        detail: "Flagged suspect#{rules.any? ? ": #{rules.join(', ')}" : ''}") ]
            end
          else
            []
          end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "Assessed as real human traffic (confidence #{confidence})",
          breakdown: payload.slice("result", "rule_ids", "invalid_traffic_type", "confidence")
        )
      end
    end
  end
end
