class Pixel < ApplicationRecord
  include TenantScoped

  STATUSES = %w[active paused revoked].freeze

  has_many :capture_sessions, dependent: :restrict_with_error
  has_many :leads, dependent: :restrict_with_error

  json_attribute :allowed_origins, default: []

  has_secure_token :signing_secret, length: 36

  before_validation :assign_public_id, on: :create

  validates :public_id, presence: true, uniqueness: true
  validates :name, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate  :allowed_origins_are_absolute

  scope :active, -> { where(status: "active") }

  def to_param = public_id

  def active? = status == "active"

  # The pixel id is public - it sits in the page source - so it cannot be a
  # credential. Origin matching is what actually binds a pixel to the pages its
  # owner authorised, and therefore what stops a third party POSTing leads into
  # this account. An empty allowlist accepts nothing rather than everything.
  def origin_allowed?(origin)
    return false if origin.blank?

    candidate = normalize_origin(origin)
    allowed_origins.any? { |allowed| normalize_origin(allowed) == candidate }
  end

  # The exact text the buyer pastes into their <head>.
  def snippet(endpoint:, script_url:)
    <<~HTML.strip
      <script async src="#{script_url}"
              data-pixel-id="#{public_id}"
              data-endpoint="#{endpoint}"></script>
    HTML
  end

  private

  def assign_public_id
    self.public_id ||= "px_#{SecureRandom.hex(3)}"
  end

  def normalize_origin(value)
    uri = URI.parse(value.to_s.strip)
    return value.to_s.strip.downcase if uri.host.blank?

    port = uri.port && uri.port != uri.default_port ? ":#{uri.port}" : ""
    "#{uri.scheme&.downcase}://#{uri.host.downcase}#{port}"
  rescue URI::InvalidURIError
    value.to_s.strip.downcase
  end

  def allowed_origins_are_absolute
    allowed_origins.each do |origin|
      uri = URI.parse(origin.to_s)
      next if uri.is_a?(URI::HTTP) && uri.host.present?

      errors.add(:allowed_origins, "#{origin.inspect} must be an absolute http(s) origin")
    rescue URI::InvalidURIError
      errors.add(:allowed_origins, "#{origin.inspect} is not a valid URL")
    end
  end
end
