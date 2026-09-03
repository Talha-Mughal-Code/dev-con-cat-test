module Engine
  module Evaluators
    # Is this lead already in THIS account's CRM, so the buyer would pay twice?
    #
    # Not a vendor - the "provider" is the buyer's own records, which is why the
    # gateway performs the match (it is the I/O boundary) and this evaluator only
    # interprets the result.
    #
    # The distinction that matters is hard vs soft:
    #
    #   hard (phone AND email) - dispositive. The buyer owns this record.
    #   soft (phone XOR email) - ADVISORY. This is a billing question, not a
    #     fraud question: same phone with a different email hours later could be
    #     a returning customer as easily as a resold lead. The brief asks for it
    #     to be surfaced for a human rather than auto-rejected, so it is priced
    #     below the ACCEPT threshold - alone it flags and accepts, combined with
    #     any other doubt it tips the lead into REVIEW.
    class DuplicateDetection < Base
      def self.module_key = "duplicate_detection"

      def call(payload, _context)
        match_type = payload["match_type"].to_s
        matches = Array(payload["matches"])

        findings =
          case match_type
          when "exact"
            [ finding(hard_stop_code: "duplicate_hard", weight_key: "hard_duplicate",
                      detail: "Exact duplicate of #{describe(matches.first)} - " \
                              "same phone and email already in this account") ]
          when "partial"
            [ finding(weight_key: "soft_duplicate", advisory: true,
                      detail: "Possible duplicate of #{describe(matches.first)} - " \
                              "matched on #{Array(matches.first&.dig('matched_on')).to_sentence}. " \
                              "Flagged for review, not rejected.") ]
          else
            []
          end

        assessment(
          findings: findings,
          summary: findings.first&.detail || "No matching record in this account",
          breakdown: {
            "match_type" => match_type.presence || "none",
            "matches" => matches,
            "searched" => payload["searched"]
          }
        )
      end

      private

      def describe(match)
        return "an existing record" if match.blank?

        parts = [ match["reference"] ].compact_blank
        parts << "created #{match['recorded_at']}" if match["recorded_at"].present?
        parts.join(", ").presence || "an existing record"
      end
    end
  end
end
