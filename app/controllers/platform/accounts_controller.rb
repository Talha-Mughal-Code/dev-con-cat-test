module Platform
  class AccountsController < BaseController
    before_action :load_account, only: :show
    # An AROUND action, not a block inside the action, and the reason is worth
    # recording: relations are lazy, so an association traversed while the
    # TEMPLATE renders runs after any block in the action has already closed.
    # A tenant user does not notice - their account is ambient for the whole
    # request - but a platform operator has no ambient account, so a
    # block-scoped read here left the view rendering with no tenant context and
    # the page 404'd. around_action wraps rendering too.
    around_action :within_account_scope, only: :show

    def index
      @accounts = Account.order(:company_name)
    end

    def show
      # Read through the account's own scope rather than a blanket bypass, so
      # even a platform operator's queries carry an account predicate.
      @stats = {
          leads: Lead.count,
          verdicts: VerificationRun.completed.group(:verdict).count,
          certificates: ConsentCertificate.count,
          pixels: Pixel.count,
        users: @account.users.count
      }
      @ledger = CreditLedgerEntry.chronological.reverse_order.limit(30).to_a
      @recent_runs = VerificationRun.recent.includes(:lead).limit(15).to_a
      @modules = @account.enabled_module_costs
      @all_modules = DetectionModule.ordered
      @policy = @account.active_consensus_policy
      @reconciliation = Credits::Ledger.reconcile(@account)
      @spend_by_module = CreditLedgerEntry.debits.group(:module_key).sum("-amount")
                                          .sort_by { |_, v| -v }
    end

    private

    def within_account_scope(&block)
      TenantScope.for_account(@account, &block)
    end

    def load_account
      @account = Account.find_by!(public_id: params[:public_id])
    end

    def audited_account
      @account || Account.find_by(public_id: params[:public_id])
    end
  end
end
