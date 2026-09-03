# Every cross-account read by a platform operator. super_admin is a genuine
# privilege escalation, so it leaves a trail that the operator cannot edit.
class AdminAccessLog < ApplicationRecord
  belongs_to :user
  belongs_to :account, optional: true

  validates :action, presence: true
  validates :occurred_at, presence: true

  scope :newest_first, -> { order(id: :desc) }

  def self.record!(user:, action:, account: nil, path: nil, ip: nil)
    create!(user: user, account: account, action: action, path: path, ip: ip,
            occurred_at: Time.current)
  end
end
