class User < ApplicationRecord
  # Not TenantScoped: authentication has to find a user by email before any
  # tenant context exists. Account-scoped user management goes through
  # `current_account.users` instead.
  ROLES = %w[super_admin account_admin member].freeze

  belongs_to :account, optional: true
  has_secure_password

  before_validation { self.email = email.to_s.downcase.strip.presence }

  validates :name, presence: true
  validates :email, presence: true, uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, inclusion: { in: ROLES }
  validates :password, length: { minimum: 12 }, allow_nil: true
  validate  :account_matches_role

  def super_admin?    = role == "super_admin"
  def account_admin?  = role == "account_admin"
  def member?         = role == "member"

  # Can this user change things inside their account (pixels, policy, users)?
  def manages_account? = account_admin?

  def display_role = role.humanize

  private

  # Mirrors the database check constraint. Belt and braces on purpose: this is
  # the invariant that keeps a tenant user from having a null account and thus
  # inheriting the platform-operator scope.
  def account_matches_role
    if super_admin? && account_id.present?
      errors.add(:account, "must be blank for a platform operator")
    elsif !super_admin? && account_id.blank?
      errors.add(:account, "is required for a tenant user")
    end
  end
end
