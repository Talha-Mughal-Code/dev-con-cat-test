# Drives the consensus engine over the mock data with no database rows.
#
# Mirrors what Verification::Orchestrator does at runtime - decide each layer's
# state, translate the payload with its evaluator, then aggregate - but sourced
# from the JSON fixtures so the engine can be tested in isolation.
module EngineHarness
  VENDOR_MODULES = %w[
    vpn_proxy anura trustedform blacklist_alliance dnc
    phone_validation email_validation enrichment voice
  ].freeze

  # Layers with no vendor behind them: always available to every account.
  FIRST_PARTY_MODULES = %w[capture_behaviour].freeze

  FAIL_CLOSED = %w[trustedform dnc blacklist_alliance duplicate_detection].freeze

  def build_lead_context(lead_data, overrides = {})
    Engine::LeadContext.new(
      public_id: lead_data["lead_id"],
      email: lead_data["email"],
      phone: lead_data["phone"],
      email_normalized: Lead.normalize_email(lead_data["email"]),
      phone_normalized: Lead.normalize_phone(lead_data["phone"]),
      landing_page_url: lead_data["landing_page_url"],
      captured_at: Time.zone.parse(lead_data["captured_at"]),
      form_dwell_ms: lead_data["form_dwell_ms"],
      # The seeded leads carry no checkbox data - see the tri-state column.
      consent_checkbox: nil,
      trusted_form_cert_url: lead_data["trusted_form_cert_url"],
      ip_address: lead_data["ip_address"],
      user_agent: lead_data["user_agent"]
    ).tap { |ctx| overrides.each { |k, v| ctx[k] = v } }
  end

  def crm_matcher_records(account_public_id)
    MockData.crm_records.fetch(account_public_id, []).map do |record|
      Providers::DuplicateMatcher::Record.new(
        reference: record["crm_id"],
        email_normalized: Lead.normalize_email(record["email"]),
        phone_normalized: Lead.normalize_phone(record["phone"]),
        recorded_at: record["created_at"],
        source: "crm"
      )
    end
  end

  def payload_for(module_key, lead_data, context)
    case module_key
    when "capture_behaviour"
      {}
    when "duplicate_detection"
      Providers::DuplicateMatcher.new(crm_matcher_records(lead_data["account_id"])).match(context)
    else
      MockData.provider_payload(module_key, lead_data["lead_id"])
    end
  end

  # Enabled modules come from the account fixture; the first-party layer is
  # always on because there is no vendor to buy.
  def enabled_modules_for(account_public_id)
    MockData.account(account_public_id).fetch("enabled_modules") + FIRST_PARTY_MODULES
  end

  def outcomes_for(lead_data, enabled: nil, unavailable: [], context_overrides: {})
    context = build_lead_context(lead_data, context_overrides)
    enabled ||= enabled_modules_for(lead_data["account_id"])

    Engine::Registry::MODULE_KEYS.map do |module_key|
      fail_closed = FAIL_CLOSED.include?(module_key)

      unless enabled.include?(module_key)
        next Engine::LayerOutcome.new(module_key: module_key, state: "not_enabled",
                                      fail_closed: fail_closed)
      end

      if unavailable.include?(module_key)
        next Engine::LayerOutcome.new(module_key: module_key, state: "errored",
                                      fail_closed: fail_closed)
      end

      evaluator = Engine::Registry.for(module_key)
      payload = payload_for(module_key, lead_data, context) || {}

      unless evaluator.applicable?(payload, context)
        next Engine::LayerOutcome.new(module_key: module_key, state: "not_applicable",
                                      fail_closed: fail_closed)
      end

      Engine::LayerOutcome.new(
        module_key: module_key, state: "completed", fail_closed: fail_closed,
        assessment: evaluator.call(payload, context)
      )
    end
  end

  def policy(rules = {})
    ConsensusPolicy.new(name: "Platform default", version: 1, active: true, rules: rules)
  end

  def evaluate(lead_public_id, policy_rules: {}, **options)
    lead_data = MockData.lead(lead_public_id)
    raise ArgumentError, "unknown lead #{lead_public_id}" if lead_data.nil?

    Engine::Consensus.new(policy(policy_rules)).call(outcomes_for(lead_data, **options))
  end
end

# Synthetic outcome builders, for testing the aggregator's arithmetic and
# fail-safe behaviour without going through a vendor payload.
module SyntheticOutcomes
  def synthetic_finding(module_key:, weight_key: nil, hard_stop_code: nil,
                        detail: "synthetic", advisory: false)
    Engine::Finding.new(module_key: module_key, weight_key: weight_key,
                        hard_stop_code: hard_stop_code, detail: detail, advisory: advisory)
  end

  def answered(module_key, findings: [], fail_closed: false, summary: "ok")
    Engine::LayerOutcome.new(
      module_key: module_key, state: "completed", fail_closed: fail_closed,
      assessment: Engine::Assessment.new(module_key: module_key, findings: Array(findings),
                                         summary: summary, breakdown: {})
    )
  end

  def unanswered(module_key, state, fail_closed: false)
    Engine::LayerOutcome.new(module_key: module_key, state: state,
                             fail_closed: fail_closed)
  end
end
