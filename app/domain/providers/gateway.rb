module Providers
  # The single I/O boundary between the engine and the outside world.
  #
  # Every layer's data arrives through here, including the two that are not
  # vendor calls at all (duplicate detection reads the buyer's CRM; capture
  # behaviour reads our own pixel telemetry). Routing them all through one
  # gateway means the engine has exactly one shape of dependency, and swapping a
  # mock for a real vendor client is a change to this file rather than to the
  # verification pipeline.
  #
  # It also models the two things about vendor calls that matter operationally
  # and that a naive in-memory stub would hide:
  #
  #   * LATENCY - each call sleeps briefly, so layers land one at a time and the
  #     live panel genuinely streams instead of appearing all at once. Set to
  #     zero in the test environment.
  #   * FAILURE - any module listed in SUPER_PIXEL_OUTAGES raises
  #     LayerUnavailable, so the fail-open / fail-closed handling can be
  #     demonstrated on a running system without editing code.
  class Gateway
    def initialize(lead:, capture_session: nil, crm_records: nil, clock: Time)
      @lead = lead
      @capture_session = capture_session || lead.capture_session
      @crm_records = crm_records
      @clock = clock
      @context = Engine::LeadContext.from(lead)
    end

    attr_reader :context

    # Returns the raw provider payload for one module, or raises
    # LayerUnavailable.
    def fetch(module_key)
      key = module_key.to_s
      raise LayerUnavailable.new(key, "simulated outage via SUPER_PIXEL_OUTAGES") if outage?(key)

      simulate_latency
      payload = case key
      when "capture_behaviour"   then capture_payload
      when "duplicate_detection" then duplicate_payload
      else vendor_payload(key)
      end

      raise LayerUnavailable.new(key, "provider returned no data") if payload.nil?

      payload
    end

    private

    attr_reader :lead, :capture_session, :clock

    # First-party telemetry. Always available, costs nothing, has no vendor
    # behind it to fail.
    def capture_payload
      summary = capture_session&.interaction_summary || {}
      {
        "interaction_count" => summary[:count],
        "fields_touched" => summary[:fields_touched],
        "visit_ip" => capture_session&.visit_ip,
        "submit_ip" => capture_session&.submit_ip,
        "ip_consistent" => capture_session&.ip_consistent?
      }.compact
    end

    # The buyer's own CRM, plus any other lead already captured for this account
    # on the same contact details. Leads that have not yet been accepted are not
    # in the CRM, but submitting the same person twice in five minutes is still a
    # duplicate the buyer should not pay for twice.
    def duplicate_payload
      DuplicateMatcher.new(@crm_records || account_records).match(context)
    end

    def account_records
      records = lead.account.crm_records.map do |record|
        DuplicateMatcher::Record.new(
          reference: record.crm_id, email_normalized: record.email_normalized,
          phone_normalized: record.phone_normalized, recorded_at: record.recorded_at,
          source: record.source == "accepted_lead" ? "crm (from an accepted lead)" : "crm"
        )
      end

      prior_leads = lead.account.leads
                        .where.not(id: lead.id)
                        .where(captured_at: ..lead.captured_at)
      prior_leads = prior_leads.where(
        "email_normalized = :email OR phone_normalized = :phone",
        email: context.email_normalized, phone: context.phone_normalized
      )

      records + prior_leads.map do |other|
        DuplicateMatcher::Record.new(
          reference: other.public_id, email_normalized: other.email_normalized,
          phone_normalized: other.phone_normalized, recorded_at: other.captured_at,
          source: "earlier capture"
        )
      end
    end

    def vendor_payload(key)
      fixture = FixtureSource.new(lead.public_id).fetch(key)
      return fixture if fixture.present?

      DerivedSource.new(context, capture_session: capture_session).fetch(key)
    end

    def outage?(key)
      self.class.simulated_outages.include?(key)
    end

    def self.simulated_outages
      @simulated_outages ||= ENV.fetch("SUPER_PIXEL_OUTAGES", "").split(",").map(&:strip).compact_blank
    end

    # Test seam: lets a test declare an outage without touching the environment.
    def self.with_outages(*keys)
      previous = simulated_outages
      @simulated_outages = keys.flatten.map(&:to_s)
      yield
    ensure
      @simulated_outages = previous
    end

    def simulate_latency
      range = Rails.configuration.x.provider_latency_ms
      return if range.blank?

      millis = range.is_a?(Range) ? rand(range) : range.to_i
      sleep(millis / 1000.0) if millis.positive?
    end
  end
end
