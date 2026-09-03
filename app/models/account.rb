class Account < ApplicationRecord
  # Account is the tenant boundary itself, so it is deliberately not
  # TenantScoped - scoping it would be circular.
  PLANS    = %w[starter growth enterprise].freeze
  STATUSES = %w[active past_due suspended].freeze

  # Warn a buyer while they can still do something about it.
  LOW_CREDIT_FRACTION = 0.20
  CRITICAL_DAYS_OF_RUNWAY = 3.0

  has_many :users, dependent: :restrict_with_error
  has_many :pixels, dependent: :restrict_with_error
  has_many :capture_sessions, dependent: :restrict_with_error
  has_many :leads, dependent: :restrict_with_error
  has_many :crm_records, dependent: :restrict_with_error
  has_many :verification_runs, dependent: :restrict_with_error
  has_many :layer_results, dependent: :restrict_with_error
  has_many :consent_certificates, dependent: :restrict_with_error
  # The ledger is append-only at the database level, so it is never cascaded.
  has_many :credit_ledger_entries
  has_many :activity_events, dependent: :delete_all
  has_many :account_modules, dependent: :destroy
  has_many :detection_modules, through: :account_modules
  has_many :consensus_policies, dependent: :destroy

  validates :public_id, presence: true, uniqueness: true
  validates :company_name, presence: true
  validates :plan, inclusion: { in: PLANS }
  validates :status, inclusion: { in: STATUSES }
  validates :monthly_credit_allowance, numericality: { greater_than_or_equal_to: 0 }

  scope :by_runway, -> { order(Arel.sql("CASE status WHEN 'past_due' THEN 0 ELSE 1 END")) }

  def to_param = public_id

  # --- credits ------------------------------------------------------------

  def credits_remaining
    monthly_credit_allowance - credits_consumed
  end

  # Trailing burn measured from the ledger, falling back to the seeded baseline
  # until there is enough history for the average to mean anything.
  def daily_burn_rate(window: 7.days)
    since = window.ago
    spent = credit_ledger_entries.where(entry_type: "debit").where(occurred_at: since..).sum(:amount).abs
    days  = [ (Time.current - [ since, created_at ].max) / 1.day, 1.0 ].max
    measured = spent / days
    measured.positive? ? measured.round : baseline_daily_burn
  end

  def days_until_dry
    burn = daily_burn_rate
    return Float::INFINITY if burn.zero?

    (credits_remaining.to_f / burn).round(2)
  end

  def credit_health
    return :exhausted if credits_remaining <= 0
    return :critical  if days_until_dry <= CRITICAL_DAYS_OF_RUNWAY
    return :low       if credits_remaining < monthly_credit_allowance * LOW_CREDIT_FRACTION

    :healthy
  end

  def needs_attention?
    past_due? || credit_health != :healthy
  end

  def past_due? = status == "past_due"

  def suspended? = status == "suspended"

  # --- modules & policy ---------------------------------------------------

  # module_key => cost in credits, for the layers this account actually pays for.
  def enabled_module_costs
    account_modules.includes(:detection_module).each_with_object({}) do |am, memo|
      next unless am.enabled?

      memo[am.detection_module.key] = am.cost_in_credits
    end
  end

  def module_enabled?(key)
    enabled_module_costs.key?(key.to_s)
  end

  # An account's own policy if it has overridden one, otherwise the platform
  # default. Accounts inherit rather than each carrying a copy, so a platform
  # policy fix reaches every account that has not deliberately diverged.
  def active_consensus_policy
    consensus_policies.where(active: true).order(version: :desc).first ||
      ConsensusPolicy.platform_default
  end
end
