module Providers
  # Duplicate detection against the buyer's own records.
  #
  # Takes plain hashes rather than ActiveRecord objects so the matching rule can
  # be unit tested against mock-data/buyers_crm.json without a database, and so
  # the same rule serves both the seeded CRM and leads captured live.
  #
  # Hard vs soft is the decision that matters:
  #
  #   exact   - phone AND email both match. The buyer owns this record.
  #   partial - one matches, the other does not. Reported with what matched and
  #             how long ago, because "same phone, different email, three hours
  #             apart" is a returning customer as plausibly as a resold lead,
  #             and that is a judgement for a human.
  class DuplicateMatcher
    Record = Struct.new(:reference, :email_normalized, :phone_normalized, :recorded_at,
                        :source, keyword_init: true)

    def initialize(records)
      @records = Array(records)
    end

    def match(lead_context)
      email = lead_context.email_normalized.presence
      phone = lead_context.phone_normalized.presence

      exact = []
      partial = []

      @records.each do |record|
        email_hit = email.present? && record.email_normalized.present? && record.email_normalized == email
        phone_hit = phone.present? && record.phone_normalized.present? && record.phone_normalized == phone
        next unless email_hit || phone_hit

        entry = {
          "reference" => record.reference,
          "source" => record.source,
          "recorded_at" => format_time(record.recorded_at),
          "matched_on" => [ phone_hit ? "phone" : nil, email_hit ? "email" : nil ].compact
        }

        (email_hit && phone_hit ? exact : partial) << entry
      end

      matches = exact.presence || partial
      {
        "match_type" => (exact.any? ? "exact" : (partial.any? ? "partial" : "none")),
        "matches" => matches,
        "searched" => {
          "records" => @records.size,
          "by_email" => email.present?,
          "by_phone" => phone.present?
        }
      }
    end

    private

    def format_time(value)
      return nil if value.blank?

      value.respond_to?(:utc) ? value.utc.iso8601 : value.to_s
    end
  end
end
