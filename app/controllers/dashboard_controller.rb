class DashboardController < ApplicationController
  def show
    authorize! :view_dashboard

    with_tenant_scope do
      @account = current_account
      @runs = VerificationRun.completed
      @verdict_counts = @runs.group(:verdict).count
      @total_leads = Lead.count
      @awaiting = Lead.awaiting_verdict.count + VerificationRun.where(status: VerificationRun::IN_FLIGHT_STATUSES).count
      @recent_leads = Lead.recent.includes(:current_verification_run, :pixel).limit(8)
      @recent_activity = ActivityEvent.newest_first.limit(12)
      @pixels = Pixel.order(:created_at)
      @credit_spend = CreditLedgerEntry.debits.group(:module_key).sum("-amount")
                                       .sort_by { |_, v| -v }.first(6)
      @layer_load = LayerResult.group(:state).count
    end
  end
end
