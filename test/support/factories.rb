# Plain builders rather than a factory gem. There are few enough entities that
# explicitness is worth more than the indirection.
module Factories
  def build_account(public_id: "acct_test", allowance: 1_000, consumed: 0,
                    plan: "growth", status: "active", modules: nil, burn: 100)
    account = Account.create!(
      public_id: public_id, company_name: "#{public_id.titleize} Ltd", plan: plan,
      status: status, monthly_credit_allowance: allowance, credits_consumed: consumed,
      cycle_start: Date.current.beginning_of_month, cycle_end: Date.current.end_of_month,
      baseline_daily_burn: burn, billing_contact: "billing@#{public_id}.example"
    )

    ensure_catalog
    keys = modules || DetectionModule.pluck(:key)
    TenantScope.for_account(account) do
      DetectionModule.find_each do |mod|
        AccountModule.create!(detection_module: mod, enabled: keys.include?(mod.key))
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

  # The detection-module catalog is reference data the whole app assumes exists.
  # Loaded from the same source of truth the seeds use so the tests cannot drift
  # from production configuration.
  def ensure_catalog
    return if DetectionModule.count.positive?

    catalog = Rails.root.join("db/module_catalog.yml")
    YAML.load_file(catalog).fetch("modules").each do |entry|
      DetectionModule.create!(entry)
    end
  end
end

class ActiveSupport::TestCase
  include Factories
end
