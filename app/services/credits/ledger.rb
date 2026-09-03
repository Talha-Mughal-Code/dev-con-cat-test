module Credits
  # Credit accounting.
  #
  # WHY A LEDGER AND A COUNTER
  # --------------------------
  # credit_ledger_entries is the source of truth: append-only, immutable at the
  # database level, one row per charge with the balance it left behind.
  # accounts.credits_consumed is a cached sum of it.
  #
  # Both exist because affordability has to be checked and committed in a single
  # atomic statement. Read-then-write would let two concurrent verifications each
  # see a sufficient balance and both spend it, and summing the ledger inside
  # that statement is not something SQLite will do cheaply. So the counter
  # carries the invariant (it is the thing the conditional UPDATE guards) and the
  # ledger carries the history - with a reconciliation test proving they never
  # disagree.
  #
  # WHEN A CREDIT IS CONSUMED
  # -------------------------
  # Per layer that actually answered. module_costs_in_credits is quoted per
  # layer, and vendor cost is incurred per call, so that is the honest unit. We
  # never charge for a layer that was not enabled, did not apply, errored, or was
  # skipped - enforced by a check constraint, not just by this class.
  class Ledger
    class << self
      def available(account)
        account.reload.credits_remaining
      end

      # Charge for one layer. Idempotent on idempotency_key, which is what makes
      # a Solid Queue retry safe: the retry hits the unique index instead of the
      # buyer's balance.
      def charge!(account:, amount:, idempotency_key:, module_key: nil,
                  verification_run: nil, layer_result: nil, description: nil)
        return nil if amount.to_i.zero?

        raise ArgumentError, "charge amount must be positive" if amount.to_i.negative?

        apply!(
          account: account, signed_amount: -amount.to_i, entry_type: "debit",
          idempotency_key: idempotency_key, module_key: module_key,
          verification_run: verification_run, layer_result: layer_result,
          description: description || "#{module_key} check",
          guard_balance: true
        )
      end

      # Give credits back - for a layer we charged for and then could not
      # deliver. Never guarded: refunds must always succeed.
      def refund!(account:, amount:, idempotency_key:, module_key: nil,
                  verification_run: nil, description: nil)
        apply!(
          account: account, signed_amount: amount.to_i.abs, entry_type: "refund",
          idempotency_key: idempotency_key, module_key: module_key,
          verification_run: verification_run, layer_result: nil,
          description: description || "refund for #{module_key}",
          guard_balance: false
        )
      end

      # accounts.json gives a credits_used_this_cycle figure with no itemised
      # history. Recording it as one rollup entry rather than writing straight
      # into the cached counter keeps the ledger authoritative from the first
      # row, so reconciliation is meaningful rather than vacuous.
      def record_opening_balance!(account:, credits_consumed:)
        return if credits_consumed.to_i.zero?

        apply!(
          account: account, signed_amount: -credits_consumed.to_i,
          entry_type: "historical_rollup",
          idempotency_key: "opening:#{account.public_id}:#{account.cycle_start.iso8601}",
          module_key: nil, verification_run: nil, layer_result: nil,
          description: "Usage carried into this cycle before itemised accounting began",
          guard_balance: false
        )
      end

      # Proves the cache has not drifted from the ledger. Used by the credits
      # test and available as a rake task for anyone who wants to check a
      # running system.
      def reconcile(account)
        ledger_consumed = TenantScope.for_account(account) do
          -CreditLedgerEntry.where(account: account).sum(:amount)
        end

        { account: account.public_id, cached: account.reload.credits_consumed,
          ledger: ledger_consumed, drift: account.credits_consumed - ledger_consumed }
      end

      private

      def apply!(account:, signed_amount:, entry_type:, idempotency_key:, module_key:,
                 verification_run:, layer_result:, description:, guard_balance:)
        TenantScope.for_account(account) do
          entry = nil

          ActiveRecord::Base.transaction do
            # Checked inside the transaction so a concurrent duplicate either
            # finds this row or trips the unique index below.
            existing = CreditLedgerEntry.find_by(idempotency_key: idempotency_key)
            next entry = existing if existing

            requested = signed_amount.abs
            if guard_balance
              # The whole point: one statement that both tests affordability and
              # commits the spend. Two concurrent charges cannot both pass,
              # because the second re-evaluates the predicate against the value
              # the first committed. A balance can therefore never go negative.
              affected = Account.where(id: account.id)
                                .where("monthly_credit_allowance - credits_consumed >= ?", requested)
                                .update_all([ "credits_consumed = credits_consumed + ?, updated_at = ?",
                                              requested, Time.current ])

              if affected.zero?
                raise InsufficientCredits.new(account: account, requested: requested,
                                              available: account.reload.credits_remaining)
              end
            else
              Account.where(id: account.id)
                     .update_all([ "credits_consumed = credits_consumed + ?, updated_at = ?",
                                   -signed_amount, Time.current ])
            end

            balance_after = Account.where(id: account.id)
                                   .pick(Arel.sql("monthly_credit_allowance - credits_consumed"))

            entry = CreditLedgerEntry.create!(
              account: account, verification_run: verification_run, layer_result: layer_result,
              entry_type: entry_type, module_key: module_key, amount: signed_amount,
              balance_after: balance_after, idempotency_key: idempotency_key,
              description: description, occurred_at: Time.current
            )
          end

          account.reload
          entry
        end
      rescue ActiveRecord::RecordNotUnique
        # Lost a race on the same idempotency key. The transaction rolled back,
        # including the counter increment, so the winner's row is the truth.
        TenantScope.for_account(account) do
          CreditLedgerEntry.find_by(idempotency_key: idempotency_key)
        end
      end
    end
  end
end
