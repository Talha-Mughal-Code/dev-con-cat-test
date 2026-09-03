class SessionsController < ApplicationController
  allow_unauthenticated only: %i[new create]

  layout "plain"

  def new
    redirect_to post_sign_in_path(current_user) and return if signed_in?

    @user = User.new
  end

  def create
    user = User.find_by(email: params.dig(:user, :email).to_s.downcase.strip)

    if user&.authenticate(params.dig(:user, :password))
      destination = session[:return_to]
      sign_in(user)
      redirect_to destination || post_sign_in_path(user), notice: "Signed in as #{user.name}."
    else
      # One message for both a bad password and an unknown address, so the form
      # cannot be used to enumerate who has an account.
      @user = User.new(email: params.dig(:user, :email))
      flash.now[:alert] = "That email and password do not match."
      render :new, status: :unprocessable_entity
    end
  end

  def destroy
    sign_out
    redirect_to new_session_path, notice: "Signed out."
  end

  private

  def post_sign_in_path(user)
    user.super_admin? ? platform_root_path : dashboard_path
  end
end
