# One layer's contribution to one run.
#
# The important design decision here is that STATE and SIGNAL are separate
# columns with a database check constraint tying them together:
#
#   state  - did this layer get to speak?  (the three states the brief calls
#            out - not_enabled / not_applicable / completed - plus the failure
#            modes: errored, timed_out, skipped_insufficient_credits)
#   signal - what did it say?  (pass / warn / fail / info, NULL unless it ran)
#
# Conflating them is the classic bug in this domain: a layer nobody paid for and
# a layer that came back clean both end up looking like "no problem found", and
# the certificate then implies a check that never happened.
class LayerResult < ApplicationRecord
  include TenantScoped

  STATES = %w[pending completed not_enabled not_applicable errored
              skipped_insufficient_credits skipped_hard_stop timed_out].freeze
  SIGNALS = %w[pass warn fail info].freeze

  # States that mean "this layer never spoke, and no evidence is missing as a
  # result" - so they do not count against coverage. skipped_hard_stop belongs
  # here because we chose it: the lead was already dispositively rejected, and
  # holding a deliberate saving against our own coverage score would be
  # incoherent. It is still reported by name on the certificate.
  SILENT_STATES = %w[not_enabled not_applicable skipped_hard_stop].freeze

  belongs_to :verification_run
  belongs_to :detection_module

  json_attribute :payload, default: {}
  json_attribute :breakdown, default: {}
  json_attribute :findings, default: []

  validates :module_key, presence: true, uniqueness: { scope: :verification_run_id }
  validates :state, inclusion: { in: STATES }
  validates :signal, inclusion: { in: SIGNALS }, allow_nil: true

  scope :answered, -> { where(state: "completed") }
  scope :in_wave, ->(n) { where(wave: n) }
  scope :ordered, -> { joins(:detection_module).order("detection_modules.position", :module_key) }

  def answered? = state == "completed"
  def pending?  = state == "pending"
  def failed_to_answer? = state.in?(%w[errored timed_out])
  def skipped_for_credits? = state == "skipped_insufficient_credits"
  def skipped_after_hard_stop? = state == "skipped_hard_stop"
  def not_enabled? = state == "not_enabled"
  def not_applicable? = state == "not_applicable"

  # What the live panel and the certificate show. Mapped from the state/signal
  # pair so the two concepts stay visible rather than being flattened into one
  # traffic light.
  def display_status
    return signal if answered?

    case state
    when "not_enabled"                  then "not_enabled"
    when "not_applicable"               then "skip"
    when "skipped_insufficient_credits" then "skipped"
    when "skipped_hard_stop"            then "skipped"
    when "errored", "timed_out"         then "unavailable"
    else "pending"
    end
  end

  def display_name = detection_module.name

  # Rehydrates the evaluator's findings so the engine can re-resolve them
  # against the policy. Persisting findings rather than a resolved score means
  # the policy is applied in exactly one place - Engine::Consensus.
  def engine_findings
    findings.map do |raw|
      Engine::Finding.new(
        module_key: raw["module_key"], hard_stop_code: raw["hard_stop_code"],
        weight_key: raw["weight_key"], detail: raw["detail"], advisory: raw["advisory"]
      )
    end
  end

  def to_engine_outcome
    assessment =
      if answered?
        Engine::Assessment.new(module_key: module_key, findings: engine_findings,
                               summary: summary, breakdown: breakdown)
      end

    Engine::LayerOutcome.new(
      module_key: module_key, state: state, assessment: assessment,
      fail_closed: detection_module.fail_closed?
    )
  end

  def to_certificate_entry
    {
      "module" => module_key,
      "name" => display_name,
      "state" => state,
      "signal" => signal,
      "hard_stop" => hard_stop,
      "risk_contribution" => risk_contribution.round(4),
      "summary" => summary,
      "credits_charged" => credits_charged,
      "executed_at" => completed_at&.utc&.iso8601,
      "latency_ms" => latency_ms,
      "evidence" => breakdown.presence || payload
    }.compact
  end
end
