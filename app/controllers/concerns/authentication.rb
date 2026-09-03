# Session-cookie authentication.
#
# Deliberately hand-rolled rather than pulled from a gem: it is thirty lines,
# the assignment asks for a login screen and session handling rather than a
# feature-complete identity system, and the interesting authorization decisions
# are the ones a gem would not make for me.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :establish_current_context
    helper_method :current_user, :signed_in?
  end

  class_methods do
    def allow_unauthenticated(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  def establish_current_context
    Current.request_id = request.request_id
    Current.ip = request.remote_ip
    Current.user_agent = request.user_agent
    Current.user = current_user
    Current.account = current_user&.account
  end

  def current_user
    return @current_user if defined?(@current_user)

    @current_user = session[:user_id] && User.find_by(id: session[:user_id])
  end

  def signed_in? = current_user.present?

  def require_authentication
    return if signed_in?

    # Remember where they were headed, but only for a GET - replaying a POST
    # after login would repeat a side effect the user did not re-authorise.
    session[:return_to] = request.fullpath if request.get?
    redirect_to new_session_path, alert: "Please sign in to continue."
  end

  def sign_in(user)
    # A fresh session id on privilege change, so a fixated pre-login session
    # cannot be reused as an authenticated one.
    reset_session
    session[:user_id] = user.id
    user.update_column(:last_login_at, Time.current)
    @current_user = user
  end

  def sign_out
    reset_session
    @current_user = nil
    Current.reset
  end
end
