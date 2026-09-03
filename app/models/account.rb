class Account < ApplicationRecord
  # Account is the tenant boundary itself, so it is deliberately not
  # TenantScoped - scoping it would be circular.
  PLANS    = %w[starter growth enterprise].freeze
  STATUSES = %w[active past_due suspended].freeze

  # Warn a buyer while they can still do something about it.
  LOW_CREDIT_FRACTION = 0.20
  CRITICAL_DAYS_OF_RUNWAY = 3.0
  # Below this much observed history, extrapolating a daily rate is arithmetic
  # rather than information: a handful of verifications in the last minute would
  # otherwise imply either an absurd burn rate or a reassuring one, depending
  # purely on when you looked.
  MIN_HISTORY_DAYS_FOR_MEASURED_BURN = 3.0
  BURN_WINDOW = 7.days

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

  # Trailing burn measured from the ledger, falling back to the account's
  # modelled rate until there is enough history for an average to mean anything.
  def daily_burn_rate
    measured_daily_burn || baseline_daily_burn
  end

  # nil when there is too little history to extrapolate from, which is the
  # honest answer rather than a confident wrong number.
  def measured_daily_burn
    return @measured_daily_burn if defined?(@measured_daily_burn)

    @measured_daily_burn = scoped_to_self do
      entries = credit_ledger_entries.debits.where(occurred_at: BURN_WINDOW.ago..)
      earliest = entries.minimum(:occurred_at)
      next nil if earliest.nil?

      span_days = (Time.current - earliest) / 1.day
      next nil if span_days < MIN_HISTORY_DAYS_FOR_MEASURED_BURN

      spent = entries.sum(:amount).abs
      next nil if spent.zero?

      (spent / span_days).round
    end
  end

  # Shown on the platform dashboard so an operator can tell a measured rate from
  # a modelled one rather than trusting both equally.
  def burn_rate_basis
    measured_daily_burn ? :measured : :modelled
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
    scoped_to_self do
      account_modules.includes(:detection_module).each_with_object({}) do |am, memo|
        next unless am.enabled?

        memo[am.detection_module.key] = am.cost_in_credits
      end
    end
  end

  def module_enabled?(key)
    enabled_module_costs.key?(key.to_s)
  end

  # An account's own policy if it has overridden one, otherwise the platform
  # default. Accounts inherit rather than each carrying a copy, so a platform
  # policy fix reaches every account that has not deliberately diverged.
  # Account is the tenant boundary, so it is allowed to read its own
  # tenant-scoped children - but it still has to say so. Without this, a
  # super_admin iterating accounts on the platform dashboard would trip the
  # tenant guard, which is the guard working correctly rather than a nuisance:
  # the read is legitimate, so it is made explicit here instead of being
  # permitted everywhere.
  def scoped_to_self(&block)
    return block.call if Current.account_id == id

    TenantScope.for_account(self, &block)
  end

  def active_consensus_policy
    consensus_policies.where(active: true).order(version: :desc).first ||
      ConsensusPolicy.platform_default
  end
end
