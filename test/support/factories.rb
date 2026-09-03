# Plain builders rather than a factory gem. There are few enough entities that
# explicitness is worth more than the indirection.
module Factories
  def build_account(public_id: "acct_test", allowance: 1_000, consumed: 0,
                    plan: "growth", status: "active", modules: nil, burn: 100)
    # Upsert rather than create, so a test that asks for the same account twice
    # gets the same account rather than a uniqueness error.
    account = Account.find_or_initialize_by(public_id: public_id)
    account.update!(
      company_name: "#{public_id.titleize} Ltd", plan: plan, status: status,
      monthly_credit_allowance: allowance, credits_consumed: consumed,
      cycle_start: Date.current.beginning_of_month, cycle_end: Date.current.end_of_month,
      baseline_daily_burn: burn, billing_contact: "billing@#{public_id}.example"
    )

    ensure_reference_data
    keys = modules || DetectionModule.pluck(:key)
    TenantScope.for_account(account) do
      DetectionModule.find_each do |mod|
        AccountModule.find_or_initialize_by(detection_module: mod)
                     .update!(enabled: keys.include?(mod.key))
      end
    end

    account
  end

  def build_user(account: nil, role: "member", email: nil, name: "Test User")
    User.create!(
      account: account, role: role, name: name,
      email: email || "#{role}-#{SecureRandom.hex(4)}@example.com",
      password: "test-password-1234", password_confirmation: "test-password-1234"
    )
  end

  def build_pixel(account:, name: "Test pixel", origins: [ "https://example.com" ], status: "active")
    TenantScope.for_account(account) do
      Pixel.create!(name: name, allowed_origins: origins, status: status)
    end
  end

  def build_lead(account:, pixel: nil, **attributes)
    TenantScope.for_account(account) do
      Lead.create!({
        pixel: pixel,
        first_name: "Test", last_name: "Lead",
        email: "test-#{SecureRandom.hex(4)}@example.com",
        phone: "+13105550#{rand(100..999)}",
        landing_page_url: "https://example.com/quote",
        captured_at: Time.current, submitted_at: Time.current,
        form_dwell_ms: 30_000, origin: "pixel"
      }.merge(attributes))
    end
  end

  def platform_policy
    ConsensusPolicy.platform_default ||
      ConsensusPolicy.create!(account_id: nil, name: "Platform default", version: 1,
                              active: true, rules: {})
  end

  # Reference data the whole application assumes exists: the module catalog and
  # the platform default policy. Loaded from the same sources the seeds use, so
  # tests cannot drift from production configuration.
  def ensure_reference_data
    if DetectionModule.count.zero?
      YAML.load_file(Rails.root.join("db/module_catalog.yml")).fetch("modules").each do |entry|
        DetectionModule.create!(entry)
      end
    end

    platform_policy
  end
end

class ActiveSupport::TestCase
  include Factories
end

# Builders that reuse the assignment's own fixture data, so a test can exercise
# the real pipeline against a known scenario (a bot, a litigator, a duplicate)
# without inventing vendor responses.
module SeededScenarios
  include Factories

  def load_provider_fixtures!(lead_public_id)
    MockData::PROVIDERS.each do |provider_key|
      payload = MockData.provider_payload(provider_key, lead_public_id)
      next if payload.nil?

      ProviderFixture.find_or_initialize_by(provider_key: provider_key,
                                            lead_public_id: lead_public_id)
                     .update!(payload: payload)
    end
  end

  # Recreates one of the twelve seeded leads, including its account's real
  # module subscriptions and CRM records, so pipeline tests run against the
  # scenario the fixture was written to exercise.
  def build_scenario(lead_public_id, allowance: 10_000, modules: nil, **account_overrides)
    data = MockData.lead(lead_public_id)
    account_public_id = data.fetch("account_id")
    account_data = MockData.account(account_public_id)

    account = build_account(
      public_id: account_public_id, allowance: allowance, consumed: 0,
      plan: account_data.fetch("plan"), burn: account_data.fetch("avg_daily_burn"),
      modules: modules || (account_data.fetch("enabled_modules") + [ "capture_behaviour" ]),
      **account_overrides
    )

    MockData.crm_records.fetch(account_public_id, []).each do |record|
      TenantScope.for_account(account) do
        CrmRecord.find_or_initialize_by(crm_id: record.fetch("crm_id")).update!(
          first_name: record["first_name"],
          last_name: record["last_name"], email: record["email"], phone: record["phone"],
          recorded_at: Time.zone.parse(record.fetch("created_at")), source: "seed"
        )
      end
    end

    load_provider_fixtures!(lead_public_id)
    pixel = build_pixel(account: account, name: "Scenario pixel",
                        origins: [ URI.join(data.fetch("landing_page_url"), "/").to_s.chomp("/") ])

    lead = build_lead(
      account: account, pixel: pixel, public_id: lead_public_id,
      first_name: data["first_name"], last_name: data["last_name"],
      email: data["email"], phone: data["phone"],
      ip_address: data["ip_address"], user_agent: data["user_agent"],
      landing_page_url: data["landing_page_url"], campaign: data["campaign"],
      form_dwell_ms: data["form_dwell_ms"],
      trusted_form_cert_url: data["trusted_form_cert_url"],
      consent_checkbox: nil, origin: "seed",
      captured_at: Time.zone.parse(data.fetch("captured_at")),
      submitted_at: Time.zone.parse(data.fetch("captured_at"))
    )

    [ account, lead ]
  end

  def verify!(lead)
    TenantScope.for_account(lead.account) { Verification::Runner.call(lead: lead) }
  end
end

class ActiveSupport::TestCase
  include SeededScenarios
end
