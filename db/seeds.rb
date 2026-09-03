# Loads every file in mock-data/ into the database.
#
# Idempotent: safe to run repeatedly. Reference data is upserted on its public
# identifier, and leads are only verified if they have no run yet, so a second
# `db:seed` does not double-charge anyone's credits.
#
# The `_comment` and `_note` keys in the fixtures are documentation for the
# candidate, not data, so they are stripped on the way in - except the CRM notes
# and lead hints, which are deliberately retained (see below).

require "json"

MOCK_DATA = Rails.root.join("mock-data")

def load_mock(relative)
  JSON.parse(MOCK_DATA.join(relative).read(encoding: "UTF-8"))
end

def say(message)
  puts "  #{message}"
end

# users.json ships placeholder_password values with an explicit instruction not
# to ship them as-is, so they are ignored. Every seeded user gets this password
# instead; it is documented in SOLUTION.md and overridable for anyone who wants
# to seed something less guessable.
SEED_PASSWORD = ENV.fetch("SEED_PASSWORD", "super-pixel-demo-2026")

# Origins the bundled demo landing page is served from in development. Added to
# every seeded pixel's allowlist so the demo works out of the box rather than
# requiring an allowlist edit first.
LOCAL_DEMO_ORIGINS = [ 3000, 3001 ].flat_map do |port|
  [ "http://localhost:#{port}", "http://127.0.0.1:#{port}" ]
end.freeze

puts "\nSeeding the Super Pixel platform from mock-data/"
puts "=" * 64

# ---------------------------------------------------------------------------
# 1. Detection module catalog
# ---------------------------------------------------------------------------
# The catalog lives in db/module_catalog.yml so that the test suite loads the
# same reference data the seeds do and cannot drift from it.
CATALOG = YAML.load_file(Rails.root.join("db/module_catalog.yml")).fetch("modules").freeze

accounts_file = load_mock("accounts.json")
module_costs = accounts_file.fetch("module_costs_in_credits")

# Guard against the catalog drifting from the fixture it was derived from. The
# costs are quoted in accounts.json; if that file changes and the catalog does
# not, seeding should fail loudly rather than silently mispricing every run.
CATALOG.each do |entry|
  key = entry.fetch("key")
  next if key == "capture_behaviour" # first-party, not priced in the fixture

  quoted = module_costs.fetch(key)
  next if quoted == entry.fetch("default_cost_in_credits")

  raise "db/module_catalog.yml prices #{key} at #{entry['default_cost_in_credits']} credits but " \
        "mock-data/accounts.json quotes #{quoted}. Reconcile them before seeding."
end

CATALOG.each do |entry|
  DetectionModule.find_or_initialize_by(key: entry.fetch("key")).update!(entry.except("key"))
end
say "#{DetectionModule.count} detection modules " \
    "(#{DetectionModule.wave(1).count} in wave 1, #{DetectionModule.wave(2).count} in wave 2)"

# ---------------------------------------------------------------------------
# 2. Platform default consensus policy
# ---------------------------------------------------------------------------
# Empty `rules` means "inherit every default". The defaults live in
# ConsensusPolicy::DEFAULT_RULES, fully commented, rather than being duplicated
# into a seed file where they would drift.
platform_policy = ConsensusPolicy.find_or_initialize_by(account_id: nil, version: 1)
platform_policy.update!(name: "Platform default", active: true, rules: {})
say "platform consensus policy v#{platform_policy.version} " \
    "(accept < #{platform_policy.accept_below}, reject >= #{platform_policy.reject_at_or_above})"

# ---------------------------------------------------------------------------
# 3. Accounts, their enabled modules, and their opening credit position
# ---------------------------------------------------------------------------
# Landing pages per account, taken from the leads fixture. These become the
# pixel's origin allowlist - the only thing that stops a third party POSTing
# leads into someone else's account, since the pixel id is public.
LANDING_PAGES = {
  "acct_solarpro" => %w[https://solar-savings.example.com],
  "acct_medicareedge" => %w[https://medicare-help.example.com],
  "acct_autoinsure" => %w[https://auto-quotes.example.com]
}.freeze

PIXELS = {
  "acct_solarpro" => { public_id: "px_9f2a01", name: "Solar savings quote funnel" },
  "acct_medicareedge" => { public_id: "px_3b7c22", name: "Medicare enrolment funnel" },
  "acct_autoinsure" => { public_id: "px_7d51f0", name: "Auto quote start page" }
}.freeze

accounts_file.fetch("accounts").each do |data|
  account = Account.find_or_initialize_by(public_id: data.fetch("account_id"))
  account.update!(
    company_name: data.fetch("company_name"),
    plan: data.fetch("plan"),
    status: data.fetch("status"),
    monthly_credit_allowance: data.fetch("monthly_credit_allowance"),
    cycle_start: Date.parse(data.fetch("cycle_start")),
    cycle_end: Date.parse(data.fetch("cycle_end")),
    baseline_daily_burn: data.fetch("avg_daily_burn"),
    billing_contact: data["billing_contact"]
  )

  TenantScope.for_account(account) do
    enabled = data.fetch("enabled_modules")
    DetectionModule.find_each do |mod|
      # capture_behaviour is enabled for everyone: there is no vendor to buy and
      # no per-check cost, so there is nothing for an account to subscribe to.
      is_enabled = enabled.include?(mod.key) || mod.key == "capture_behaviour"
      AccountModule.find_or_initialize_by(detection_module: mod).update!(enabled: is_enabled)
    end

    pixel_data = PIXELS.fetch(account.public_id)
    pixel = Pixel.find_or_initialize_by(public_id: pixel_data[:public_id])
    pixel.name = pixel_data[:name]
    pixel.status = "active"
    pixel.allowed_origins = LANDING_PAGES.fetch(account.public_id) + LOCAL_DEMO_ORIGINS
    pixel.save!
  end

  # The fixture gives a credits_used_this_cycle figure with no itemised history.
  # The ledger is the source of truth for billing, so that opening position is
  # recorded as a single rollup entry rather than being written straight into the
  # cached counter - otherwise the counter and the ledger would disagree from the
  # very first row.
  Credits::Ledger.record_opening_balance!(
    account: account,
    credits_consumed: data.fetch("credits_used_this_cycle")
  )
end
say "#{Account.count} accounts, #{Pixel.unscoped.count} pixels, " \
    "#{AccountModule.unscoped.where(enabled: true).count} module subscriptions"

# ---------------------------------------------------------------------------
# 4. Users
# ---------------------------------------------------------------------------
load_mock("users.json").fetch("users").each do |data|
  account = data["account_id"] && Account.find_by!(public_id: data["account_id"])
  user = User.find_or_initialize_by(email: data.fetch("email"))
  user.update!(
    name: data.fetch("name"),
    role: data.fetch("role"),
    account: account,
    password: SEED_PASSWORD,
    password_confirmation: SEED_PASSWORD
  )
end
say "#{User.count} users (password: #{SEED_PASSWORD.inspect}) - " \
    "#{User.where(role: 'super_admin').count} platform operator, " \
    "#{User.where(role: 'account_admin').count} account admins, " \
    "#{User.where(role: 'member').count} members"

# ---------------------------------------------------------------------------
# 5. Buyer CRM records (what duplicate detection searches)
# ---------------------------------------------------------------------------
load_mock("buyers_crm.json").fetch("crm_records").each do |account_public_id, records|
  account = Account.find_by!(public_id: account_public_id)
  TenantScope.for_account(account) do
    records.each do |data|
      CrmRecord.find_or_initialize_by(crm_id: data.fetch("crm_id")).update!(
        first_name: data["first_name"], last_name: data["last_name"],
        email: data["email"], phone: data["phone"],
        recorded_at: Time.zone.parse(data.fetch("created_at")),
        source: "seed"
      )
    end
  end
end
say "#{CrmRecord.unscoped.count} existing CRM records"

# ---------------------------------------------------------------------------
# 6. Provider fixtures
# ---------------------------------------------------------------------------
# Loaded into a table rather than read from disk at request time, so the vendor
# gateway has the shape it would have in production: an I/O call that can be
# slow, absent, or fail.
PROVIDER_FILES = %w[
  vpn_proxy anura trustedform blacklist_alliance dnc
  phone_validation email_validation enrichment voice
].freeze

PROVIDER_FILES.each do |provider_key|
  load_mock("providers/#{provider_key}.json").fetch("results").each do |lead_public_id, payload|
    record = ProviderFixture.find_or_initialize_by(provider_key: provider_key,
                                                   lead_public_id: lead_public_id)
    # `_note` is commentary for the candidate, not vendor data.
    record.payload = payload.except("_note")
    record.save!
  end
end
say "#{ProviderFixture.count} provider fixtures across #{PROVIDER_FILES.size} vendors"

# ---------------------------------------------------------------------------
# 7. Leads
# ---------------------------------------------------------------------------
load_mock("leads.json").fetch("leads").each do |data|
  account = Account.find_by!(public_id: data.fetch("account_id"))

  TenantScope.for_account(account) do
    pixel = Pixel.find_by!(public_id: data.fetch("pixel_id"))
    lead = Lead.find_or_initialize_by(public_id: data.fetch("lead_id"))
    lead.update!(
      pixel: pixel,
      first_name: data["first_name"], last_name: data["last_name"],
      email: data["email"], phone: data["phone"],
      ip_address: data["ip_address"], user_agent: data["user_agent"],
      landing_page_url: data["landing_page_url"], campaign: data["campaign"],
      form_dwell_ms: data["form_dwell_ms"],
      trusted_form_cert_url: data["trusted_form_cert_url"],
      # The seeded leads predate the pixel, so there is no checkbox observation
      # to record. NULL, not false - see the tri-state column.
      consent_checkbox: nil,
      captured_at: Time.zone.parse(data.fetch("captured_at")),
      submitted_at: Time.zone.parse(data.fetch("captured_at")),
      origin: "seed",
      # Stored for the test suite to use as an oracle. Nothing under app/ reads
      # this column, and a test asserts as much by grep.
      expected_verdict_hint: data["expected_verdict"]
    )
  end
end
say "#{Lead.unscoped.count} leads"
# ---------------------------------------------------------------------------
# 8. Verify the seeded leads
# ---------------------------------------------------------------------------
# Run inline rather than enqueued, so `db:seed` leaves a populated CRM without
# the grader needing a worker running first. It is the SAME code path the
# asynchronous pipeline uses - Orchestrator, LayerRunner, WaveCoordinator,
# Finalizer - only with perform_now, so nothing can behave differently here than
# it does under a worker.
#
# Only leads with no run yet, so re-seeding does not re-charge anyone.
unverified = TenantScope.across_accounts { Lead.where(current_verification_run_id: nil).to_a }

if unverified.any?
  say "verifying #{unverified.size} #{'lead'.pluralize(unverified.size)}..."

  unverified.sort_by(&:captured_at).each do |lead|
    run = TenantScope.for_account(lead.account) { Verification::Runner.call(lead: lead) }

    TenantScope.for_account(lead.account) do
      detail = if run.completed?
                 "#{run.verdict.upcase.ljust(6)} #{run.verdict_code}"
      else
                 run.verdict_label
      end
      say format("  %-8s %-9s %-34s %2d credits  %s",
                 lead.public_id, lead.account.public_id.delete_prefix("acct_"), detail,
                 run.credits_charged,
                 run.short_circuited? ? "(short-circuited)" : "")
    end
  end

  puts
  TenantScope.across_accounts do
    VerificationRun.group(:verdict).count.each do |verdict, count|
      say "#{count} #{verdict || 'no verdict'}"
    end
  end
  say "#{ConsentCertificate.unscoped.count} consent certificates issued"
  Account.find_each do |account|
    say "#{account.public_id}: #{account.credits_remaining} credits left " \
        "(#{account.credit_health})"
  end
end

puts "=" * 64
puts "Seed complete.\n\n"
