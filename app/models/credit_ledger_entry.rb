# Append-only credit ledger. This is the source of truth for billing;
# accounts.credits_consumed is a cache of its current-cycle sum.
#
# Why both: affordability has to be checked and committed in a single atomic
# UPDATE (see Credits::Charger) or two concurrent runs can each read a
# sufficient balance and both spend it. Summing the ledger inside that UPDATE is
# not something SQLite will do cheaply, so the counter carries the invariant and
# the ledger carries the truth - with a reconciliation test proving they agree.
class CreditLedgerEntry < ApplicationRecord
  include TenantScoped

  ENTRY_TYPES = %w[debit refund allowance_grant historical_rollup adjustment].freeze

  belongs_to :verification_run, optional: true
  belongs_to :layer_result, optional: true

  validates :entry_type, inclusion: { in: ENTRY_TYPES }
  validates :amount, numericality: { other_than: 0 }
  validates :idempotency_key, presence: true, uniqueness: true
  validates :occurred_at, presence: true

  scope :debits, -> { where(entry_type: "debit") }
  scope :chronological, -> { order(:occurred_at, :id) }

  # Enforced by a database trigger as well; this is the friendly half.
  def readonly? = persisted?

  def consumed? = amount.negative?

  def credits = amount.abs
end
