module Platform
  # The platform operator's own access log, shown to the platform operator.
  #
  # Deliberately visible rather than write-only: an audit trail nobody can see
  # is a compliance decoration. Making it a screen means an operator knows their
  # cross-account reads are recorded, which is most of the deterrent.
  class AuditLogsController < BaseController
    def index
      @logs = AdminAccessLog.newest_first.includes(:user, :account).limit(200)
      @by_user = AdminAccessLog.group(:user_id).count
    end
  end
end
