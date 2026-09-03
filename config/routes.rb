Rails.application.routes.draw do
  # --- authentication -------------------------------------------------------
  resource :session, only: %i[new create destroy]
  get "/login", to: "sessions#new", as: :login
  delete "/logout", to: "sessions#destroy", as: :logout

  # --- the buyer's own surfaces (always scoped to their account) ------------
  get "/dashboard", to: "dashboard#show", as: :dashboard

  resources :leads, only: %i[index show], param: :public_id do
    member do
      post :reverify
      # Server-sent events for a lead still being verified, so the CRM detail
      # page updates live for exactly the same reason the landing page does.
      get :activity
    end
  end

  resources :pixels, only: %i[index show new create edit update], param: :public_id

  resource :policy, only: %i[show update], controller: "policies"

  get "/activity", to: "activity#index", as: :activity_feed

  # Certificates are addressed by serial, never by database id: the serial is
  # the credential a third party is given.
  resources :certificates, only: %i[show], param: :serial do
    member { get :verify }
  end

  # --- platform operator ----------------------------------------------------
  namespace :platform do
    root to: "dashboard#show"
    resources :accounts, only: %i[index show], param: :public_id
    resources :audit_logs, only: :index
  end

  # --- the pixel's public API ------------------------------------------------
  # Called cross-origin from a buyer's landing page, so these are CSRF-exempt
  # and origin-checked instead. See Api::Pixel::BaseController.
  namespace :api do
    namespace :pixel do
      post "/visit", to: "visits#create"
      post "/leads", to: "leads#create"
      get "/leads/:lead_public_id/activity", to: "activity#show", as: :lead_activity
      match "/*path", to: "base#preflight", via: :options
    end
  end

  # Public certificate verification. No authentication: a buyer hands the serial
  # to a third party, who must be able to check authenticity without an account
  # here - and without being shown the lead's personal data.
  get "/verify/:serial", to: "public_certificates#show", as: :public_certificate
  get "/.well-known/super-pixel-certificate-key", to: "public_certificates#public_key"

  # --- the demo funnel ------------------------------------------------------
  # The assignment's landing page, served by the app with a real pixel id and a
  # real endpoint so it exercises the live backend rather than the simulation.
  get "/demo", to: "demo#show", as: :demo
  get "/demo/:pixel_public_id", to: "demo#show", as: :demo_for_pixel

  get "/up", to: "rails/health#show", as: :rails_health_check
  root to: "sessions#new"
end
