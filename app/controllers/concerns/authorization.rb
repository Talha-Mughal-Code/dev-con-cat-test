# Role authorization.
#
# The brief asks for authorization to be enforced rather than have buttons
# hidden, so this raises - and the raise becomes a 404. Never a redirect that
# happens to work because the view rendered nothing.
#
# It is the second of two independent defences. Tenant ISOLATION is enforced in
# SQL by TenantScope, so a member of account A cannot load account B's lead at
# all. This layer answers a different question: given that you can see this
# record, are you allowed to do this to it?
module Authorization
  extend ActiveSupport::Concern

  class NotAuthorized < StandardError; end

  included do
    # A missing record and a forbidden one both return 404. Distinguishing them
    # would tell an outsider which ids exist, which is itself a leak - so the
    # cross-tenant case (RecordNotFound, raised by the tenant scope) and the
    # forbidden case are deliberately indistinguishable from outside.
    rescue_from ActiveRecord::RecordNotFound, with: :render_not_found
    rescue_from Authorization::NotAuthorized, with: :render_not_found
    rescue_from TenantScope::MissingTenantContext, with: :render_not_found

    helper_method :allowed_to?
  end

  private

  def authorize!(action, record = nil)
    return if allowed_to?(action, record)

    raise NotAuthorized, "#{Current.user&.role || 'anonymous'} may not #{action}"
  end

  def allowed_to?(action, record = nil)
    Permissions.new(Current.user).allow?(action, record)
  end

  def render_not_found(exception)
    Rails.logger.info("denied #{request.method} #{request.path}: #{exception.class}: #{exception.message}")

    respond_to do |format|
      format.html { render "shared/not_found", status: :not_found, layout: "application" }
      format.json { render json: { error: "not_found" }, status: :not_found }
      format.any  { head :not_found }
    end
  end
end
