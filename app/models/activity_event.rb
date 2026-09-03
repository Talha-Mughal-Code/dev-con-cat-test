# The append-only stream that powers three things at once: the per-account
# activity timeline, the audit trail, and the real-time feed the landing page
# tails over SSE.
#
# One table rather than three because they are the same facts viewed
# differently, and because a monotonic primary key is exactly the cursor SSE
# needs - a reconnecting client sends Last-Event-ID and we replay from there
# with no gaps and no duplicates.
class ActivityEvent < ApplicationRecord
  include TenantScoped

  KINDS = %w[
    session_started lead_received run_started layer_result
    final_verdict certificate_issued run_halted run_errored
    credits_low credits_exhausted crm_record_created
  ].freeze

  belongs_to :lead, optional: true
  belongs_to :verification_run, optional: true
  belongs_to :capture_session, optional: true
  belongs_to :pixel, optional: true

  json_attribute :payload, default: {}

  validates :kind, inclusion: { in: KINDS }
  validates :occurred_at, presence: true

  scope :chronological, -> { order(:id) }
  scope :newest_first, -> { order(id: :desc) }
  scope :after_cursor, ->(cursor) { cursor.to_i.positive? ? where("id > ?", cursor.to_i) : all }

  # The wire format consumed by the pixel's event bus. Named to match the
  # contract in docs/pixel-spec.md so the reference landing page needed no
  # changes to its rendering code.
  def to_stream_event
    {
      id: id,
      type: stream_type,
      kind: kind,
      occurred_at: occurred_at.utc.iso8601(3)
    }.merge(payload.symbolize_keys)
  end

  def stream_type
    case kind
    when "layer_result"   then "layer_result"
    when "final_verdict"  then "final_verdict"
    when "run_halted", "run_errored", "credits_exhausted" then "final_verdict"
    else "info"
    end
  end

  def headline
    payload["headline"].presence || kind.humanize
  end
end
