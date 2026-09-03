namespace :leads do
  desc "Verify leads that have no verification run yet (inline, no worker needed)"
  task verify: :environment do
    leads = TenantScope.across_accounts { Lead.where(current_verification_run_id: nil).to_a }
    abort "Every lead already has a run. Use leads:reverify to run them again." if leads.empty?

    leads.each do |lead|
      run = TenantScope.for_account(lead.account) { Verification::Runner.call(lead: lead) }
      puts "#{lead.public_id}: #{run.verdict_label} (#{run.credits_charged} credits)"
    end
  end

  desc "Re-verify a lead against the current policy, e.g. LEAD=L-1009 rake leads:reverify"
  task reverify: :environment do
    public_id = ENV.fetch("LEAD") { abort "Set LEAD=L-1001" }
    lead = TenantScope.across_accounts { Lead.find_by!(public_id: public_id) }

    # A new run rather than a mutated one: the verdict belongs to the run, so
    # history is preserved and the old certificate stays valid for whatever it
    # was used to justify.
    run = TenantScope.for_account(lead.account) { Verification::Runner.call(lead: lead) }
    TenantScope.for_account(lead.account) do
      puts "#{lead.public_id} attempt #{run.attempt}: #{run.verdict_label} (#{run.verdict_code})"
      run.reasons.each { |r| puts "  - #{r['message']}" }
    end
  end

  desc "Reconcile every account's cached credit counter against its ledger"
  task reconcile_credits: :environment do
    Account.find_each do |account|
      report = Credits::Ledger.reconcile(account)
      status = report[:drift].zero? ? "ok" : "DRIFT #{report[:drift]}"
      puts format("%-20s cached %-8d ledger %-8d %s",
                  report[:account], report[:cached], report[:ledger], status)
    end
  end
end
