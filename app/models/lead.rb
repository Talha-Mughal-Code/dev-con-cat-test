class Lead < ApplicationRecord
  include TenantScoped

  ORIGINS = %w[seed pixel].freeze

  belongs_to :pixel, optional: true
  belongs_to :capture_session, optional: true

  has_many :verification_runs, dependent: :destroy
  has_many :activity_events, dependent: :delete_all
  has_many :consent_certificates, dependent: :restrict_with_error
  has_one  :crm_record, dependent: :nullify

  belongs_to :current_verification_run, class_name: "VerificationRun", optional: true

  before_validation :assign_public_id, on: :create
  before_validation :normalize_contact_details

  validates :public_id, presence: true, uniqueness: true
  validates :captured_at, presence: true
  validates :origin, inclusion: { in: ORIGINS }

  scope :recent, -> { order(captured_at: :desc) }
  scope :with_verdict, ->(verdict) { joins(:current_verification_run).where(verification_runs: { verdict: verdict }) }
  scope :awaiting_verdict, -> { where(current_verification_run_id: nil) }

  def to_param = public_id

  def full_name = [ first_name, last_name ].compact_blank.join(" ").presence || "(no name)"

  def verdict = current_verification_run&.verdict

  def certificate = current_verification_run&.consent_certificate

  # Free-text search across the fields a CRM user would actually paste in.
  def self.search(term)
    term = term.to_s.strip
    return all if term.blank?

    like = "%#{term.downcase}%"
    digits = term.gsub(/\D/, "")
    relation = where(
      "LOWER(first_name) LIKE :like OR LOWER(last_name) LIKE :like OR " \
      "LOWER(email) LIKE :like OR LOWER(public_id) LIKE :like",
      like: like
    )
    relation = relation.or(where("phone_normalized LIKE ?", "%#{digits}%")) if digits.length >= 4
    relation
  end

  # Normalisation happens once, on write, so duplicate detection is an indexed
  # equality lookup instead of a table scan that normalises every row.
  def self.normalize_email(value)
    value.to_s.strip.downcase.presence
  end

  # Deliberately naive but predictable E.164 handling for NANP numbers, which is
  # all the fixture data contains. A production system would use a real
  # libphonenumber binding; the important part is that matching compares
  # normalised values, not whatever the form happened to submit.
  def self.normalize_phone(value)
    digits = value.to_s.gsub(/\D/, "")
    return nil if digits.blank?

    case digits.length
    when 10 then "+1#{digits}"
    when 11 then digits.start_with?("1") ? "+#{digits}" : "+#{digits}"
    else "+#{digits}"
    end
  end

  private

  def assign_public_id
    self.public_id ||= "L-#{SecureRandom.hex(5).upcase}"
  end

  def normalize_contact_details
    self.email_normalized = self.class.normalize_email(email)
    self.phone_normalized = self.class.normalize_phone(phone)
  end
end
