# One evaluation of one lead under one policy version.
#
# Modelled separately from the lead because re-verification is a real
# requirement, not a hypothetical: a vendor outage, a policy change, or an
# account topping up after a halted run all warrant a fresh run against the same
# lead. Keeping the verdict on the run means history is preserved and
# `lead.current_verification_run` is just a pointer at the latest one.
class VerificationRun < ApplicationRecord
  include TenantScoped

  STATUSES = %w[pending wave_1 wave_2 finalizing completed
                halted_insufficient_credits errored].freeze
  IN_FLIGHT_STATUSES = %w[pending wave_1 wave_2 finalizing].freeze
  VERDICTS = %w[accept review reject].freeze

  belongs_to :lead
  belongs_to :consensus_policy
  has_many :layer_results, dependent: :destroy
  has_many :activity_events, dependent: :delete_all
  has_one  :consent_certificate, dependent: :restrict_with_error
  has_many :credit_ledger_entries

  json_attribute :reasons, default: []

  validates :status, inclusion: { in: STATUSES }
  validates :verdict, inclusion: { in: VERDICTS }, allow_nil: true

  scope :completed, -> { where(status: "completed") }
  scope :recent, -> { order(created_at: :desc) }

  def completed? = status == "completed"
  def running?   = status.in?(IN_FLIGHT_STATUSES)
  def halted?    = status == "halted_insufficient_credits"
  def errored?   = status == "errored"

  def accepted? = verdict == "accept"
  def rejected? = verdict == "reject"
  def review?   = verdict == "review"

  # A halted run makes NO claim about the lead. It is deliberately neither an
  # accept nor a reject, and it never gets a certificate.
  def verdict_label
    return verdict.upcase if verdict
    return "HALTED - NO CREDITS" if halted?
    return "ERRORED" if errored?

    "IN PROGRESS"
  end

  def coverage_ratio
    return 1.0 if coverage_applicable.zero?

    coverage_answered.to_f / coverage_applicable
  end

  def duration_ms
    return nil unless started_at && completed_at

    ((completed_at - started_at) * 1000).round
  end

  def primary_reason
    reasons.first&.fetch("message", nil)
  end

  def layer_results_by_key
    layer_results.includes(:detection_module).index_by(&:module_key)
  end

  # Rebuilds what the engine needs from persisted rows. Layers run in separate
  # jobs, so the finaliser cannot rely on anything held in memory - the database
  # is the coordination substrate.
  def engine_outcomes
    layer_results.includes(:detection_module).map(&:to_engine_outcome)
  end

  def short_circuited_layers
    layer_results.where(state: "skipped_hard_stop")
  end

  # Layers the buyer paid for and that spoke, in display order.
  def answered_results
    layer_results.select(&:answered?)
  end

  def hard_stop_results
    layer_results.select(&:hard_stop?)
  end
end
