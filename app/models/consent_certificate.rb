# The artefact a buyer would put in front of a regulator or a plaintiff's
# counsel: what was checked, what each layer said, what verdict followed, and
# the retained TrustedForm reference - signed, so it can be shown to be the
# document we issued rather than one edited afterwards.
#
# Three layers of tamper-evidence, in increasing strength:
#
#   1. content_digest - SHA-256 over a canonical (key-sorted) JSON rendering, so
#      the digest is stable regardless of hash ordering.
#   2. signature - Ed25519 over that digest. Asymmetric on purpose: the buyer's
#      counsel can verify against our published public key without trusting us
#      and without us handing out a shared secret.
#   3. prev_digest / chain_index - a per-account hash chain. A signature proves
#      one document was not edited; the chain additionally proves none were
#      deleted or reordered, which is the attack a platform operator (us) would
#      be in a position to attempt.
#
# The signed `payload` is stored verbatim rather than re-derived from live rows
# at verification time, so later legitimate edits elsewhere in the system can
# never invalidate an issued certificate.
class ConsentCertificate < ApplicationRecord
  include TenantScoped

  SCHEMA_VERSION = 1

  belongs_to :verification_run
  belongs_to :lead

  json_attribute :payload, default: {}

  validates :serial, presence: true, uniqueness: true
  validates :content_digest, presence: true
  validates :signature, presence: true
  validates :issued_at, presence: true
  validates :chain_index, presence: true, uniqueness: { scope: :account_id }

  scope :chronological, -> { order(:chain_index) }

  # Immutable once issued, except for revocation, which is additive.
  def readonly?
    persisted? && !@revoking
  end

  def to_param = serial

  def revoked? = revoked_at.present?

  def revoke!(reason:)
    @revoking = true
    update!(revoked_at: Time.current, revocation_reason: reason)
  ensure
    @revoking = false
  end

  def verify = Certificates::Verifier.new(self).verify

  def verdict = payload.dig("verdict", "value")

  def trusted_form_reference = payload.dig("consent", "trusted_form_cert_url")

  def canonical_json = payload.present? ? Certificates::Canonical.dump(payload) : self[:payload]
end
