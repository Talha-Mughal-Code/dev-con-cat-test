module Platform
  class AccountsController < BaseController
    before_action :load_account, only: :show

    def index
      @accounts = Account.order(:company_name)
    end

    def show
      # Read through the account's own scope rather than a blanket bypass, so
      # even here the query carries an account predicate.
      TenantScope.for_account(@account) do
        @stats = {
          leads: Lead.count,
          verdicts: VerificationRun.completed.group(:verdict).count,
          certificates: ConsentCertificate.count,
          pixels: Pixel.count,
          users: @account.users.count
        }
        @ledger = CreditLedgerEntry.chronological.reverse_order.limit(30)
        @recent_runs = VerificationRun.recent.includes(:lead).limit(15)
        @modules = @account.enabled_module_costs
        @all_modules = DetectionModule.ordered
        @policy = @account.active_consensus_policy
        @reconciliation = Credits::Ledger.reconcile(@account)
        @spend_by_module = CreditLedgerEntry.debits.group(:module_key).sum("-amount")
                                            .sort_by { |_, v| -v }
      end
    end

    private

    def load_account
      @account = Account.find_by!(public_id: params[:public_id])
    end

    def audited_account
      @account || Account.find_by(public_id: params[:public_id])
    end
  end
end
