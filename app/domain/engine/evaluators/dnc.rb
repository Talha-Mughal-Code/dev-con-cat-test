module Engine
  module Evaluators
    # Do-Not-Call status and callback-window logic. The brief's own summary is
    # the whole rationale: "if you can't call it, you shouldn't buy it."
    class Dnc < Base
      def self.module_key = "dnc"

      def call(payload, _context)
        status = payload["dnc_status"].to_s
        findings = []

        if status.in?(%w[dnc_listed internal_dnc])
          scopes = []
          scopes << "national DNC" if truthy?(payload["national_dnc"])
          scopes << "state DNC" if truthy?(payload["state_dnc"])
          scopes << "the buyer's internal DNC" if truthy?(payload["internal_dnc"])
          findings << finding(
            hard_stop_code: "dnc_listed", weight_key: "listed",
            detail: "Listed on #{scopes.presence&.to_sentence || 'a Do-Not-Call list'}"
          )
        end

        # Reported separately from the listing because they are different legal
        # facts with different remedies - a closed window may reopen, a DNC
        # listing will not.
        if falsey?(payload["callback_window_open"])
          findings << finding(
            hard_stop_code: "callback_window_closed", weight_key: "window_closed",
            detail: "Callback window is closed" \
                    "#{payload['last_contact_at'].present? ? " (last contact #{payload['last_contact_at']})" : ''}"
          )
        end

        assessment(
          findings: findings,
          summary: findings.map(&:detail).presence&.to_sentence || "Callable, callback window open",
          breakdown: payload.slice("dnc_status", "national_dnc", "state_dnc", "internal_dnc",
                                   "callback_window_open", "last_contact_at")
        )
      end
    end
  end
end
