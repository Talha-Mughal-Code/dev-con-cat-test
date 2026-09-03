class ApplicationController < ActionController::Base
  include Authentication
  include Authorization

  before_action :require_authentication

  helper_method :current_account

  private

  # Tenant users work inside their own account for the whole request. Platform
  # operators have no account, so they get no ambient scope at all - see
  # Platform::BaseController, which is the only place that opens a cross-account
  # read, and which logs when it does.
  def with_tenant_scope(&block)
    return block.call if Current.user&.super_admin?

    TenantScope.for_account(Current.account, &block)
  end

  def current_account = Current.account
end
