module Engine
  module Evaluators
    # Three independent phone providers - a consensus in miniature, and the
    # clearest illustration of the brief's central idea. What matters is whether
    # they AGREE, not what any one of them said.
    #
    # Two grades of disagreement, priced differently on purpose:
    #
    #   validity_disagreement  - they cannot agree whether the number exists.
    #   line_type_disagreement - they agree it exists but not what kind of line
    #                            it is. Weaker, so cheaper.
    class PhoneValidation < Base
      def self.module_key = "phone_validation"

      def call(payload, _context)
        providers = payload["providers"] || {}
        return assessment(summary: "No phone provider responses", breakdown: payload) if providers.empty?

        valid = providers.select { |_, r| truthy?(r["valid"]) }
        invalid = providers.reject { |_, r| truthy?(r["valid"]) }
        line_types = providers.values.filter_map { |r| r["line_type"].presence }.uniq

        findings = []

        if invalid.size > valid.size
          findings << finding(
            weight_key: "majority_invalid",
            detail: "#{invalid.size} of #{providers.size} providers say the number is not reachable " \
                    "(#{invalid.keys.join(', ')})"
          )
        elsif invalid.any?
          findings << finding(
            weight_key: "validity_disagreement",
            detail: "Providers disagree on whether the number exists: " \
                    "#{valid.size} valid (#{valid.keys.join(', ')}) vs " \
                    "#{invalid.size} invalid (#{invalid.keys.join(', ')})"
          )
        elsif line_types.size > 1
          findings << finding(
            weight_key: "line_type_disagreement",
            detail: "All providers agree the number is valid but disagree on line type " \
                    "(#{line_types.join(' / ')})"
          )
        elsif line_types == [ "voip" ]
          # Reachable, but VoIP numbers are cheap to churn and are the line type
          # of choice for disposable identities.
          findings << finding(
            weight_key: "all_voip",
            detail: "All providers agree the number is VoIP" \
                    "#{carriers(providers).any? ? " (#{carriers(providers).join(', ')})" : ''}"
          )
        end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "#{valid.size}/#{providers.size} providers agree: valid #{line_types.first} number",
          breakdown: {
            "providers" => providers,
            "agreement" => {
              "valid" => valid.keys, "invalid" => invalid.keys,
              "line_types" => line_types, "unanimous" => invalid.empty? && line_types.size <= 1
            }
          }
        )
      end

      private

      def carriers(providers)
        providers.values.filter_map { |r| r["carrier"].presence }.uniq
      end
    end
  end
end
