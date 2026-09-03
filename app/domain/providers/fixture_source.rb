module Providers
  # The mock vendor responses for the twelve seeded leads, keyed by lead id
  # exactly as mock-data/providers/*.json is.
  class FixtureSource
    def initialize(lead_public_id)
      @lead_public_id = lead_public_id
    end

    def fetch(provider_key)
      ProviderFixture.lookup(provider_key, @lead_public_id)
    end

    def covers?
      ProviderFixture.where(lead_public_id: @lead_public_id).exists?
    end
  end
end
