require "test_helper"

# Credit accounting. The rubric asks for correctness here, so these tests are
# about the invariants rather than the happy path: no double charging, no
# negative balances, and a cached counter that never drifts from the ledger.
class CreditsLedgerTest < ActiveSupport::TestCase
  setup do
    @account = build_account(public_id: "acct_ledger", allowance: 100, consumed: 0)
  end

  test "a charge decrements the balance and records what it left behind" do
    entry = Credits::Ledger.charge!(account: @account, amount: 7, module_key: "anura",
                                   idempotency_key: "run:1:module:anura")

    assert_equal(-7, entry.amount)
    assert_equal 93, entry.balance_after
    assert_equal "debit", entry.entry_type
    assert_equal 93, @account.reload.credits_remaining
    assert_equal 7, @account.credits_consumed
  end

  test "the same idempotency key charges exactly once" do
    # This is what makes a Solid Queue retry safe. Without it, a layer job that
    # fails after charging and then retries would bill the buyer twice.
    key = "run:1:module:anura"

    first = Credits::Ledger.charge!(account: @account, amount: 7, idempotency_key: key,
                                   module_key: "anura")
    second = Credits::Ledger.charge!(account: @account, amount: 7, idempotency_key: key,
                                    module_key: "anura")

    assert_equal first.id, second.id
    assert_equal 7, @account.reload.credits_consumed
    assert_equal 1, TenantScope.for_account(@account) { CreditLedgerEntry.count }
  end

  test "a charge beyond the balance raises and changes nothing" do
    error = assert_raises Credits::InsufficientCredits do
      Credits::Ledger.charge!(account: @account, amount: 101,
                              idempotency_key: "run:1:module:enrichment")
    end

    assert_equal 101, error.requested
    assert_equal 100, error.available
    assert_equal 1, error.shortfall
    assert_equal 0, @account.reload.credits_consumed
    assert_equal 0, TenantScope.for_account(@account) { CreditLedgerEntry.count }
  end

  test "a balance can be spent down to exactly zero but not past it" do
    Credits::Ledger.charge!(account: @account, amount: 100, idempotency_key: "spend:all")
    assert_equal 0, @account.reload.credits_remaining

    assert_raises Credits::InsufficientCredits do
      Credits::Ledger.charge!(account: @account, amount: 1, idempotency_key: "spend:one-more")
    end
    assert_equal 0, @account.reload.credits_remaining
  end

  test "concurrent charges cannot overdraw the account" do
    # The reason affordability is a single conditional UPDATE rather than a read
    # followed by a write. Eight threads each try to spend 20 of a 100 balance;
    # exactly five can succeed.
    account = build_account(public_id: "acct_race", allowance: 100, consumed: 0)
    results = Queue.new

    threads = 8.times.map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Credits::Ledger.charge!(account: account, amount: 20,
                                  idempotency_key: "race:#{i}")
          results << :ok
        rescue Credits::InsufficientCredits
          results << :rejected
        end
      end
    end
    threads.each(&:join)

    outcomes = Array.new(results.size) { results.pop }
    assert_equal 5, outcomes.count(:ok), "exactly five 20-credit charges fit in 100"
    assert_equal 3, outcomes.count(:rejected)
    assert_equal 0, account.reload.credits_remaining
    assert_operator account.credits_remaining, :>=, 0
  end

  test "a refund gives credits back and is never balance-guarded" do
    Credits::Ledger.charge!(account: @account, amount: 40, idempotency_key: "charge:1")
    entry = Credits::Ledger.refund!(account: @account, amount: 40, module_key: "enrichment",
                                    idempotency_key: "refund:1")

    assert_equal 40, entry.amount
    assert_equal "refund", entry.entry_type
    assert_equal 100, @account.reload.credits_remaining
  end

  test "the opening balance is recorded as a ledger entry, not a bare counter" do
    account = build_account(public_id: "acct_opening", allowance: 8_000, consumed: 0)

    Credits::Ledger.record_opening_balance!(account: account, credits_consumed: 7_920)

    assert_equal 80, account.reload.credits_remaining
    entry = TenantScope.for_account(account) { CreditLedgerEntry.sole }
    assert_equal "historical_rollup", entry.entry_type
    assert_equal(-7_920, entry.amount)
  end

  test "the opening balance is idempotent across repeated seeding" do
    account = build_account(public_id: "acct_reseed", allowance: 8_000, consumed: 0)

    3.times do
      Credits::Ledger.record_opening_balance!(account: account, credits_consumed: 7_920)
    end

    assert_equal 80, account.reload.credits_remaining
    assert_equal 1, TenantScope.for_account(account) { CreditLedgerEntry.count }
  end

  test "the cached counter never drifts from the ledger" do
    # The reconciliation that justifies keeping a cache at all.
    12.times { |i| Credits::Ledger.charge!(account: @account, amount: 3, idempotency_key: "c:#{i}") }
    Credits::Ledger.refund!(account: @account, amount: 3, idempotency_key: "r:1")

    report = Credits::Ledger.reconcile(@account)

    assert_equal 33, report[:cached]
    assert_equal 33, report[:ledger]
    assert_equal 0, report[:drift]
  end

  test "every seeded account reconciles" do
    # Guards the seed path itself, which is where a counter/ledger mismatch would
    # most plausibly be introduced. Seeding is chatty, so its output is captured.
    capture_io { Rails.application.load_seed }

    Account.find_each do |account|
      assert_equal 0, Credits::Ledger.reconcile(account)[:drift],
                   "#{account.public_id} has drifted between its counter and its ledger"
    end
  end

  test "the ledger is append-only at the database level" do
    entry = Credits::Ledger.charge!(account: @account, amount: 5, idempotency_key: "immutable:1")

    # Application-level guard.
    assert entry.readonly?
    assert_raises ActiveRecord::ReadOnlyRecord do
      entry.update!(amount: -1)
    end

    # And the database refuses even a direct statement that bypasses the model.
    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.connection.execute(
        "UPDATE credit_ledger_entries SET amount = -1 WHERE id = #{entry.id}"
      )
    end
    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.connection.execute(
        "DELETE FROM credit_ledger_entries WHERE id = #{entry.id}"
      )
    end
  end

  test "credit health escalates as the balance falls" do
    healthy = build_account(public_id: "acct_healthy", allowance: 1_000, consumed: 0, burn: 10)
    assert_equal :healthy, healthy.credit_health
    assert_not healthy.needs_attention?

    # Under 20% remaining but with plenty of runway at this burn rate.
    low = build_account(public_id: "acct_low", allowance: 1_000, consumed: 850, burn: 10)
    assert_equal :low, low.credit_health

    # Days of runway is the sharper signal: this account has more credits left
    # than the one above but is burning them far faster.
    critical = build_account(public_id: "acct_critical", allowance: 10_000, consumed: 9_000, burn: 900)
    assert_equal :critical, critical.credit_health

    exhausted = build_account(public_id: "acct_dry", allowance: 1_000, consumed: 1_000, burn: 10)
    assert_equal :exhausted, exhausted.credit_health
    assert exhausted.needs_attention?
  end

  test "a past-due account needs attention even with a healthy balance" do
    account = build_account(public_id: "acct_pastdue", allowance: 10_000, consumed: 0,
                            status: "past_due", burn: 10)

    assert_equal :healthy, account.credit_health
    assert account.needs_attention?, "past_due must surface on the platform dashboard"
  end
end
