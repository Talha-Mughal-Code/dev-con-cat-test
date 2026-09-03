# The mock vendor responses from mock-data/providers/*.json.
#
# Loaded into a table at seed time rather than read from disk at request time so
# that the vendor gateway has the shape it would have in production: an I/O call
# that can be slow, missing, or fail. Swapping in a real vendor client means
# replacing one class in app/providers, not restructuring the engine.
class ProviderFixture < ApplicationRecord
  json_attribute :payload, default: {}

  validates :provider_key, presence: true
  validates :lead_public_id, presence: true, uniqueness: { scope: :provider_key }

  def self.lookup(provider_key, lead_public_id)
    find_by(provider_key: provider_key.to_s, lead_public_id: lead_public_id)&.payload
  end
end
