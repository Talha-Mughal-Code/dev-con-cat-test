# Request- (and job-) local context. Set once at the edge - in
# ApplicationController for web requests, in ApplicationJob for background work
# - and read by the tenant scope. Using CurrentAttributes rather than passing an
# account through every call site is what makes it possible to enforce isolation
# at the query layer instead of relying on every developer to remember.
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :account, :request_id, :ip, :user_agent
  # Explicit, audited escape hatch for the two legitimate cross-account
  # contexts: platform-operator reads and job bootstrapping.
  attribute :tenant_bypass

  def account=(account)
    super
    Rails.logger.push_tags(account.public_id) if account && Rails.logger.respond_to?(:push_tags)
  end

  def account_id
    account&.id
  end

  def super_admin?
    user&.super_admin?
  end
end
