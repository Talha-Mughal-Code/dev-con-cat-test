# One page view instrumented by the pixel. Created by the /visit beacon before
# the visitor has typed anything, which is what lets the VPN layer later compare
# the IP they browsed from against the IP they submitted from.
class CaptureSession < ApplicationRecord
  include TenantScoped

  belongs_to :pixel
  has_one :lead, dependent: :nullify

  json_attribute :interactions, default: []

  before_validation :assign_public_id, on: :create

  validates :public_id, presence: true, uniqueness: true
  validates :started_at, presence: true

  def submitted? = submitted_at.present?

  def ip_consistent?
    return nil if visit_ip.blank? || submit_ip.blank?

    visit_ip == submit_ip
  end

  def dwell_ms
    return nil unless submitted_at && started_at

    ((submitted_at - started_at) * 1000).round
  end

  # Evidence about *how* the form was filled, not just what was in it. Retained
  # on the certificate because "the visitor focused six fields over 48 seconds"
  # is the sort of thing that makes a consent claim defensible.
  def interaction_summary
    events = interactions
    {
      count: events.size,
      fields_touched: events.filter_map { |e| e["name"] }.uniq,
      first_at: events.first&.fetch("at", nil),
      last_at: events.last&.fetch("at", nil)
    }
  end

  private

  def assign_public_id
    self.public_id ||= "sess_#{SecureRandom.hex(8)}"
  end
end
