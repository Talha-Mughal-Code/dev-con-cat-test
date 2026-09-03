module Engine
  module Evaluators
    # Consent certificate retain-and-verify.
    #
    # This evaluator deliberately does NOT just read the vendor's `status`
    # string. docs/provider-modules.md lists four things to check - the cert
    # exists, matches the lead's phone and email, is not expired, and its page
    # fingerprint matches the claimed landing page - so all four are checked
    # independently. Trusting a summary field would mean the one layer our whole
    # product rests on is the one layer we never actually verify.
    #
    # Expiry is judged against when the lead was CAPTURED, not against now. The
    # question a certificate answers is "was consent validly retained at the
    # moment this person submitted the form", and a cert that lapses next year
    # does not retroactively invalidate consent given today.
    class Trustedform < Base
      def self.module_key = "trustedform"

      def call(payload, context)
        problems = []
        status = payload["status"].to_s

        if payload.blank? || status == "not_found"
          problems << "no retained certificate was found"
        else
          problems << "certificate phone does not match the lead" if falsey?(payload["matches_phone"])
          problems << "certificate email does not match the lead" if falsey?(payload["matches_email"])
          problems << "certificate had already expired at capture" if expired_at_capture?(payload, context)
          problems << page_problem(payload, context) if page_mismatch?(payload, context)
          # Keep the vendor's own view if it disagrees with ours, so the evidence
          # records both rather than silently overriding it.
          problems << "provider reports status '#{status}'" if status.in?(%w[mismatch expired]) && problems.empty?
        end

        findings = []
        if problems.any?
          findings << finding(
            hard_stop_code: "consent_unverifiable",
            weight_key: "unverifiable",
            detail: "Consent cannot be proven: #{problems.compact.to_sentence}"
          )
        elsif falsey?(payload["consent_language_present"])
          # The cert is valid but the page it captured carried no TCPA language.
          # Weighted rather than dispositive: there is a retained cert, and the
          # buyer may have other evidence of consent.
          findings << finding(weight_key: "consent_language_absent",
                              detail: "Certificate is valid but the page captured no TCPA consent language")
        end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "Certificate retained and verified against this lead's phone, email and landing page",
          breakdown: payload.slice("status", "cert_created_at", "expires_at", "matches_phone",
                                   "matches_email", "page_url", "consent_language_present", "notes")
                            .merge("claimed_landing_page" => context.landing_page_url,
                                   "retained_cert_url" => context.trusted_form_cert_url).compact
        )
      end

      private

      def expired_at_capture?(payload, context)
        expires_at = parse_time(payload["expires_at"])
        return false if expires_at.blank? || context.captured_at.blank?

        expires_at < context.captured_at
      end

      def page_mismatch?(payload, context)
        cert_page = payload["page_url"].to_s
        claimed = context.landing_page_url.to_s
        return false if cert_page.blank? || claimed.blank?

        normalize_url(cert_page) != normalize_url(claimed)
      end

      def page_problem(payload, _context)
        "page fingerprint (#{payload['page_url']}) differs from the claimed landing page"
      end

      def normalize_url(value)
        uri = URI.parse(value)
        "#{uri.scheme}://#{uri.host}#{uri.path.to_s.chomp('/')}".downcase
      rescue URI::InvalidURIError
        value.to_s.strip.downcase
      end

      def parse_time(value)
        value.present? ? Time.zone.parse(value.to_s) : nil
      rescue ArgumentError
        nil
      end
    end
  end
end
