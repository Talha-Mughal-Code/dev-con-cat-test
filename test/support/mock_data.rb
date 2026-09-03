# Loads the assignment's mock-data files straight from disk.
#
# The engine tests use this rather than database seeds on purpose: app/engine is
# a pure function of (payload, lead context), so its tests should not need a
# database, a seed run, or a job queue. If these tests pass, the consensus logic
# is correct independently of any plumbing around it.
module MockData
  ROOT = Rails.root.join("mock-data")

  PROVIDERS = %w[
    vpn_proxy anura trustedform blacklist_alliance dnc
    phone_validation email_validation enrichment voice
  ].freeze

  class << self
    def leads = load_file("leads.json").fetch("leads")

    def lead(public_id) = leads.find { |l| l["lead_id"] == public_id }

    def accounts = load_file("accounts.json").fetch("accounts")

    def account(public_id) = accounts.find { |a| a["account_id"] == public_id }

    def module_costs = load_file("accounts.json").fetch("module_costs_in_credits")

    def users = load_file("users.json").fetch("users")

    def crm_records = load_file("buyers_crm.json").fetch("crm_records")

    def provider(name) = load_file("providers/#{name}.json").fetch("results")

    def provider_payload(name, lead_public_id)
      provider(name)[lead_public_id]&.except("_note")
    end

    private

    def load_file(relative)
      @files ||= {}
      @files[relative] ||= JSON.parse(ROOT.join(relative).read)
    end
  end
end
