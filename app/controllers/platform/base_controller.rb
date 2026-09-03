module Platform
  # The only place in the application that reads across accounts.
  #
  # HOW super_admin IS DIFFERENT, AND HOW THAT POWER IS KEPT FROM LEAKING:
  #
  #   1. A platform operator has account_id = NULL, so the tenant default scope
  #      RAISES for them rather than returning everything. They cannot browse
  #      tenant data by accident: every ordinary controller would 500, not leak.
  #   2. Cross-account reads happen only inside TenantScope.across_accounts, and
  #      that block is only opened here - in a controller that requires the role.
  #   3. Every request through this controller writes an AdminAccessLog row. The
  #      operator cannot edit it: the model is append-only in practice and the
  #      log is visible in the UI, so the audit trail is a real deterrent rather
  #      than a table nobody reads.
  #   4. Permissions grants a platform operator only view_* verbs. There is no
  #      capability anywhere that lets them write tenant data, so there is
  #      nothing for a bug to escalate into.
  class BaseController < ApplicationController
    before_action :require_platform_operator
    before_action :log_platform_access

    layout "platform"

    private

    def require_platform_operator
      authorize! :view_platform
    end

    def log_platform_access
      AdminAccessLog.record!(
        user: Current.user, action: "#{controller_name}##{action_name}",
        path: request.fullpath, ip: request.remote_ip, account: audited_account
      )
    end

    # Overridden by controllers that drill into one account, so the log records
    # whose data was read rather than only that something was.
    def audited_account = nil

    def across_accounts(&block)
      TenantScope.across_accounts(&block)
    end
  end
end
