module Platform
  # The cross-account overview the brief asks for: plans, balances, burn rate,
  # and who is about to run dry.
  class DashboardController < BaseController
    def show
      @accounts = Account.order(:company_name).to_a

      # Sorted by urgency rather than alphabetically, because the entire point
      # of this screen is that the operator sees the account about to run dry
      # without having to look for it.
      @accounts_by_urgency = @accounts.sort_by { |account| [ urgency_rank(account), account.days_until_dry ] }
      @needs_attention = @accounts.select(&:needs_attention?)

      across_accounts do
        @totals = {
          accounts: @accounts.size,
          leads: Lead.count,
          runs: VerificationRun.count,
          certificates: ConsentCertificate.count,
          credits_allowed: @accounts.sum(&:monthly_credit_allowance),
          credits_consumed: @accounts.sum(&:credits_consumed)
        }
        @verdict_counts = VerificationRun.completed.group(:verdict).count
        @halted = VerificationRun.where(status: "halted_insufficient_credits").count
        @spend_by_module = CreditLedgerEntry.debits.group(:module_key).sum("-amount")
                                            .sort_by { |_, v| -v }
        # Loaded eagerly inside the bypass. A lazy relation would be walked
        # while the template renders, by which point the block has closed and a
        # platform operator has no ambient tenant context.
        @recent_events = ActivityEvent.newest_first.limit(15).includes(:account).to_a
      end

      @account_stats = @accounts.index_with { |account| stats_for(account) }
    end

    private

    def urgency_rank(account)
      return 0 if account.past_due? && account.credit_health != :healthy
      return 1 if account.credit_health == :exhausted
      return 2 if account.credit_health == :critical
      return 3 if account.past_due?
      return 4 if account.credit_health == :low

      5
    end

    def stats_for(account)
      TenantScope.for_account(account) do
        {
          leads: Lead.count,
          verdicts: VerificationRun.completed.group(:verdict).count,
          halted: VerificationRun.where(status: "halted_insufficient_credits").count,
          modules_enabled: account.enabled_module_costs.size,
          full_stack_cost: account.enabled_module_costs.values.sum,
          spent_this_cycle: CreditLedgerEntry.debits
                                             .where(occurred_at: account.cycle_start.beginning_of_day..)
                                             .sum("-amount")
        }
      end
    end
  end
end
