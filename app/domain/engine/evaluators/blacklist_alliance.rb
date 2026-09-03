module Engine
  module Evaluators
    # Serial TCPA litigator / professional plaintiff screening.
    class BlacklistAlliance < Base
      def self.module_key = "blacklist_alliance"

      def call(payload, _context)
        status = payload["status"].to_s
        score = payload["match_score"]
        sources = Array(payload["sources"])
        notes = payload["notes"]

        findings =
          case status
          when "litigator"
            [ finding(hard_stop_code: "litigator_confirmed", weight_key: "confirmed",
                      detail: "Confirmed serial litigator (match score #{score}" \
                              "#{sources.any? ? ", sources: #{sources.join(', ')}" : ''})") ]
          when "suspected"
            # Both a hard-stop CANDIDATE and a weighted signal. The policy
            # decides which it is; disarmed by default, so out of the box this
            # contributes 0.30 and lands the lead in REVIEW - the honest answer
            # for "possibly a plaintiff".
            [ finding(hard_stop_code: "litigator_suspected", weight_key: "suspected",
                      detail: "Suspected professional plaintiff (match score #{score}, not confirmed)" \
                              "#{notes.present? ? " - #{notes}" : ''}") ]
          else
            []
          end

        assessment(
          findings: findings,
          summary: findings.first&.detail || "No litigator match",
          breakdown: payload.slice("status", "match_score", "sources", "notes")
        )
      end
    end
  end
end
