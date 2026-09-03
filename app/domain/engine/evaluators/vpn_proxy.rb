module Engine
  module Evaluators
    # VPN / proxy / Tor / datacenter classification, plus the "VPN problem" the
    # brief describes: a visitor who browses on their real IP then submits
    # through a VPN (or the reverse).
    #
    # The IP-match check lives here rather than in CaptureBehaviour because it is
    # what this module is documented to do, and because the two facts compound -
    # an anonymised IP that also changed between visit and submit is worse than
    # either alone, and pricing it as one condition avoids double-counting.
    class VpnProxy < Base
      def self.module_key = "vpn_proxy"

      def call(payload, _context)
        anonymiser = anonymiser_kinds(payload)
        mismatch = falsey?(payload["site_visit_ip_matches_submit_ip"])
        risk = payload["risk"].to_s

        findings = []

        if anonymiser.any? && mismatch
          findings << finding(
            weight_key: "anonymizer_with_ip_mismatch",
            detail: "Submitted through #{anonymiser.to_sentence} from a different IP than the " \
                    "site visit - classic VPN masking"
          )
        elsif anonymiser.any?
          findings << finding(weight_key: "anonymizer",
                              detail: "IP is #{anonymiser.to_sentence}")
        elsif mismatch
          findings << finding(weight_key: "ip_mismatch",
                              detail: "Site-visit IP does not match the submission IP")
        elsif risk.in?(%w[medium high])
          findings << finding(weight_key: "elevated_risk",
                              detail: "Provider rates this IP as #{risk} risk")
        end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "Residential IP, consistent between site visit and submission",
          breakdown: payload.slice("is_vpn", "is_proxy", "is_tor", "is_datacenter",
                                   "site_visit_ip_matches_submit_ip", "risk", "notes")
        )
      end

      private

      # A datacenter IP counts as an anonymiser even with no VPN/proxy/Tor flag:
      # consumers do not fill in solar quotes from AWS.
      def anonymiser_kinds(payload)
        kinds = []
        kinds << "a VPN" if truthy?(payload["is_vpn"])
        kinds << "a proxy" if truthy?(payload["is_proxy"])
        kinds << "a Tor exit node" if truthy?(payload["is_tor"])
        kinds << "a datacenter IP" if truthy?(payload["is_datacenter"])
        kinds
      end
    end
  end
end
