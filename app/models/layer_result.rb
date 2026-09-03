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
              skipped_insufficient_credits timed_out].freeze
  SIGNALS = %w[pass warn fail info].freeze

  # States that mean "this layer never spoke, and that is not its fault or ours"
  # - they do not count against coverage.
  NON_APPLICABLE_STATES = %w[not_enabled not_applicable].freeze

  belongs_to :verification_run
  belongs_to :detection_module

  json_attribute :payload, default: {}
  json_attribute :breakdown, default: {}

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
    when "errored", "timed_out"         then "unavailable"
    else "pending"
    end
  end

  def display_name = detection_module.name

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
