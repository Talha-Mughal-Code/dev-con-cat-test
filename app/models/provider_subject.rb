# The mock vendors' subject index: which contact details each seeded fixture
# describes.
#
# Deliberately NOT tenant-scoped. A vendor's database is global - Blacklist
# Alliance recognises a litigator's phone number regardless of which buyer is
# asking - so this is vendor reference data, keyed by contact details, exactly
# as the real thing would be.
#
# Modelling it as tenant data would be wrong twice over: the lookup would be
# confined to the asking account and therefore never match, and it would let one
# account's lead rows influence another account's verdicts through a back door.
class ProviderSubject < ApplicationRecord
  validates :lead_public_id, presence: true, uniqueness: true

  # Matches the way a vendor would: on either identifier, since a fraudster
  # reusing a phone number with a fresh email is the common case.
  def self.matching(email:, phone:)
    return none if email.blank? && phone.blank?

    clauses = []
    binds = {}
    if email.present?
      clauses << "email_normalized = :email"
      binds[:email] = email
    end
    if phone.present?
      clauses << "phone_normalized = :phone"
      binds[:phone] = phone
    end

    where(clauses.join(" OR "), **binds)
  end
end
