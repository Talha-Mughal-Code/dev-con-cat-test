module Verification
  # What happens when an account runs out of credits mid-verification.
  #
  # The important decision: a halted run gets NO VERDICT. Not an accept, not a
  # reject, not even a review.
  #
  #   * Accepting would vouch for a lead we did not finish checking - the exact
  #     liability the product exists to remove.
  #   * Rejecting would destroy a lead that may be perfectly good, and punish
  #     the buyer twice for a billing problem.
  #
  # So the run records what it managed to check, issues no certificate, and the
  # lead sits in the CRM flagged as unverified and re-runnable. A database check
  # constraint enforces the invariant independently: a verdict may only exist on
  # a run whose status is 'completed', so no future code path can accidentally
  # let a halted run look like an approval.
  #
  # Credits already spent on layers that did answer are NOT refunded - the vendor
  # calls really were made and really did cost us. The buyer keeps the evidence
  # those layers produced.
  class Halter
    def self.call(...) = new(...).call

    def initialize(run:, shortfall:, ran: nil)
      @run = run
      @shortfall = shortfall
      @ran = ran
    end

    def call
      TenantScope.for_account(run.account) do
        run.layer_results.where(state: "pending").update_all(
          state: "skipped_insufficient_credits",
          summary: "Not run: account is out of credits",
          completed_at: Time.current, updated_at: Time.current
        )

        run.update!(status: "halted_insufficient_credits", verdict: nil,
                    completed_at: Time.current)

        Activity::Recorder.run_halted(run, shortfall: shortfall,
                                           ran: ran || run.layer_results.answered.count)
        Activity::Recorder.credits_exhausted(run.account)
      end

      run
    end

    private

    attr_reader :run, :shortfall, :ran
  end
end
