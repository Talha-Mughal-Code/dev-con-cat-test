class LeadsController < ApplicationController
  include ActionController::Live

  before_action :load_lead, only: %i[show reverify activity]

  # Deliberately no `params[:account_id]` anywhere in this controller. There is
  # nothing to tamper with: the account comes from the session and the tenant
  # scope puts it in the SQL, so `Lead.find_by!(public_id: ...)` cannot reach
  # another account's row.
  def index
    authorize! :view_leads

    with_tenant_scope do
      @filters = filter_params
      @leads = filtered_leads
      @page = [ params[:page].to_i, 1 ].max
      @per_page = 25
      @total = @leads.count
      @leads = @leads.recent.includes(:pixel, current_verification_run: :consent_certificate)
                     .offset((@page - 1) * @per_page).limit(@per_page)
      @verdict_counts = filtered_leads.joins(:current_verification_run)
                                      .group("verification_runs.verdict").count
      @pixels = Pixel.order(:name)
    end
  end

  def show
    authorize! :view_lead, @lead

    with_tenant_scope do
      @run = @lead.current_verification_run
      @layer_results = @run ? @run.layer_results.ordered.includes(:detection_module) : []
      @certificate = @run&.consent_certificate
      @events = ActivityEvent.where(lead: @lead).chronological
      @previous_runs = @lead.verification_runs.where.not(id: @run&.id).recent
      @duplicate_candidates = duplicate_candidates
    end
  end

  # Re-verification creates a NEW run rather than mutating the old one, so the
  # history and any certificate already relied upon stay intact.
  def reverify
    authorize! :reverify_lead, @lead

    with_tenant_scope { Verification::StartJob.perform_later(@lead.id) }
    redirect_to lead_path(@lead), notice: "Re-verification queued for #{@lead.public_id}."
  end

  # SSE for a lead mid-flight. Same transport and same cursor semantics as the
  # pixel's public stream - see Api::Pixel::ActivityController for the reasoning.
  def activity
    authorize! :view_lead, @lead

    response.headers["Content-Type"] = "text/event-stream"
    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Accel-Buffering"] = "no"

    Sse::Streamer.new(
      stream: response.stream,
      lead_id: @lead.id,
      account: current_account,
      cursor: request.headers["Last-Event-ID"] || params[:cursor]
    ).call
  ensure
    response.stream.close
  end

  private

  def load_lead
    with_tenant_scope { @lead = Lead.find_by!(public_id: params[:public_id]) }
  end

  def filter_params
    params.permit(:q, :verdict, :status, :pixel, :from, :to, :flagged).to_h.symbolize_keys
  end

  def filtered_leads
    scope = Lead.all
    scope = scope.search(@filters[:q]) if @filters[:q].present?

    if @filters[:verdict].present?
      scope = scope.joins(:current_verification_run)
                   .where(verification_runs: { verdict: @filters[:verdict] })
    end

    if @filters[:status].present?
      scope = scope.joins(:current_verification_run)
                   .where(verification_runs: { status: @filters[:status] })
    end

    scope = scope.joins(:pixel).where(pixels: { public_id: @filters[:pixel] }) if @filters[:pixel].present?
    scope = scope.where(captured_at: parse_date(@filters[:from])..) if @filters[:from].present?
    scope = scope.where(captured_at: ..parse_date(@filters[:to]).end_of_day) if @filters[:to].present?

    # Leads a human should look at: anything in review, plus anything carrying
    # an advisory flag such as a soft duplicate.
    if @filters[:flagged].present?
      scope = scope.joins(:current_verification_run)
                   .where("verification_runs.verdict = 'review' OR verification_runs.reasons LIKE '%advisory%'")
    end

    scope
  end

  def parse_date(value)
    Date.parse(value.to_s)
  rescue Date::Error
    Date.current
  end

  # Other records in this account on the same phone or email. Shown on the
  # detail page so a reviewer can judge a soft duplicate for themselves rather
  # than trusting the flag.
  def duplicate_candidates
    return [] if @lead.phone_normalized.blank? && @lead.email_normalized.blank?

    CrmRecord.where("phone_normalized = :phone OR email_normalized = :email",
                    phone: @lead.phone_normalized, email: @lead.email_normalized)
             .where.not(lead_id: @lead.id)
             .order(recorded_at: :desc).limit(5)
  end
end
