module Engine
  module Evaluators
    # Two enrichment sources appending identity and address.
    #
    # The value is cross-validation, so the interesting cases are the failures
    # of it: sources that contradict each other cannot corroborate anything, and
    # an enriched identity that is not the person who filled the form is a
    # different problem again.
    class Enrichment < Base
      SOURCES = %w[audiencelabs bytemine].freeze
      # Compared loosely - two sources writing the same address in different
      # formats agree, and treating that as a contradiction would flag half the
      # good leads.
      COMPARED_FIELDS = %w[address age_band].freeze

      def self.module_key = "enrichment"

      def call(payload, _context)
        sources = SOURCES.index_with { |key| payload[key] || {} }
        matched = sources.select { |_, data| truthy?(data["matched"]) }

        findings = []

        if matched.empty?
          findings << finding(
            weight_key: "unresolved",
            detail: "Neither enrichment source could resolve this identity"
          )
        elsif matched.size < sources.size
          missing = (sources.keys - matched.keys)
          findings << finding(
            weight_key: "single_source",
            detail: "Only #{matched.keys.join(', ')} resolved the identity; " \
                    "#{missing.join(', ')} could not - single-source coverage only"
          )
        end

        if matched.any? { |_, data| falsey?(data["match_to_lead"]) }
          mismatched = matched.select { |_, data| falsey?(data["match_to_lead"]) }.keys
          findings << finding(
            weight_key: "identity_mismatch",
            detail: "Enriched identity from #{mismatched.join(', ')} does not match the submitted lead"
          )
        end

        if matched.size == sources.size && (conflicts = conflicting_fields(matched)).any?
          findings << finding(
            weight_key: "sources_disagree",
            detail: "Enrichment sources disagree on #{conflicts.to_sentence} for the same identity"
          )
        end

        assessment(
          findings: findings,
          summary: findings.first&.detail ||
                   "Both sources agree and match the submitted lead" \
                   "#{matched.values.first['address'].present? ? " (#{matched.values.first['address']})" : ''}",
          breakdown: {
            "sources" => sources,
            "agreement" => {
              "resolved_by" => matched.keys,
              "conflicting_fields" => matched.size == sources.size ? conflicting_fields(matched) : [],
              "matches_lead" => matched.values.all? { |d| truthy?(d["match_to_lead"]) }
            }
          }
        )
      end

      private

      def conflicting_fields(matched)
        COMPARED_FIELDS.select do |field|
          values = matched.values.filter_map { |data| normalize(data[field]) }
          values.uniq.size > 1
        end
      end

      def normalize(value)
        value.to_s.downcase.gsub(/[^a-z0-9]/, "").presence
      end
    end
  end
end
