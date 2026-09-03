module Engine
  module Evaluators
    # The pixel's own evidence: how the form was filled, and whether the
    # consent box was ticked.
    #
    # The only layer with no vendor behind it, and therefore the only one that
    # costs nothing and can never be unavailable. Worth having as a first-class
    # layer rather than a special case: it is genuinely part of what a "super
    # pixel" knows that a vendor cannot, and it is the signal a human can
    # actually move in the live demo.
    class CaptureBehaviour < Base
      # 1.5s is not a threshold anyone could type a name, email and phone
      # inside. The bot lead in the fixtures managed 640ms.
      INSTANT_FILL_MS = 1_500
      # Fast enough to be worth a glance - paste-and-submit, or a returning
      # visitor with autofill. Priced low precisely because autofill is innocent.
      FAST_FILL_MS = 5_000

      def self.module_key = "capture_behaviour"

      def call(payload, context)
        findings = []
        dwell = context.form_dwell_ms

        if dwell.present?
          if dwell < INSTANT_FILL_MS
            findings << finding(weight_key: "instant_fill",
                                detail: "Form completed in #{dwell}ms - too fast for a human to type")
          elsif dwell < FAST_FILL_MS
            findings << finding(weight_key: "fast_fill",
                                detail: "Form completed in #{dwell}ms - unusually fast")
          end
        end

        # Only a captured-and-unchecked box is a signal. A lead with no checkbox
        # data at all is silent here, not penalised for consent it was never
        # asked to give.
        if context.consent_captured? && falsey?(context.consent_checkbox)
          findings << finding(weight_key: "consent_declined",
                              detail: "TCPA consent checkbox was presented and left unchecked")
        end

        assessment(
          findings: findings,
          summary: summarise(dwell, context, findings),
          breakdown: {
            "form_dwell_ms" => dwell,
            "consent_checkbox" => context.consent_captured? ? context.consent_checkbox : "not_captured",
            "interaction_count" => payload["interaction_count"],
            "fields_touched" => payload["fields_touched"]
          }.compact
        )
      end

      private

      def summarise(dwell, context, findings)
        return findings.first.detail if findings.any?

        parts = []
        parts << "#{(dwell / 1000.0).round(1)}s dwell" if dwell.present?
        parts << "consent checkbox ticked" if truthy?(context.consent_checkbox)
        parts << "no checkbox data captured" unless context.consent_captured?
        "Capture behaviour consistent with a human: #{parts.join(', ')}"
      end
    end
  end
end
