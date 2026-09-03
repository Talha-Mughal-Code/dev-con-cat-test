# A record already in the buyer's CRM. Seeded from mock-data/buyers_crm.json and
# then appended to whenever a lead is accepted, so duplicate detection reflects
# what the buyer actually owns rather than a frozen snapshot.
class CrmRecord < ApplicationRecord
  include TenantScoped

  belongs_to :lead, optional: true

  before_validation :normalize_contact_details
  before_validation :assign_crm_id, on: :create

  validates :crm_id, presence: true, uniqueness: { scope: :account_id }
  validates :recorded_at, presence: true

  def full_name = [ first_name, last_name ].compact_blank.join(" ")

  private

  def assign_crm_id
    self.crm_id ||= "CRM-#{SecureRandom.hex(4).upcase}"
  end

  def normalize_contact_details
    self.email_normalized = Lead.normalize_email(email)
    self.phone_normalized = Lead.normalize_phone(phone)
  end
end
