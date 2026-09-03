module Verification
  # Rescues runs that stopped moving.
  #
  # WHY THIS IS NEEDED. Layers run as jobs, and a job can exhaust its retries -
  # under heavy write contention, or if a worker is killed mid-flight. When that
  # happens the run sits in wave_1 or wave_2 forever: no verdict, no
  # certificate, and a lead the buyer paid to capture that nobody ever decides
  # about. Load testing produced exactly this, which is how it was found.
  #
  # WHAT IT DOES. For a run stuck past the threshold, any layer still pending is
  # recorded as timed_out - which is truthful, and which feeds the existing
  # fail-open / fail-closed handling rather than inventing new behaviour. Then
  # the run is finalised on whatever evidence did arrive.
  #
  # So a stuck run resolves to a verdict the engine can defend: a consent-
  # critical layer that never answered caps it at REVIEW, coverage below the
  # floor caps it at REVIEW, and a hard stop that did land still rejects. What it
  # will never do is silently accept a lead most of whose checks never ran.
  #
  # Deliberately NOT a retry. If a layer's jobs have already exhausted their
  # retries, running them again is unlikely to help and would delay the buyer
  # further. Re-verification is available on demand for that.
  class StaleRunSweeper
    # Generous relative to a normal run (a few seconds), so this only ever
    # catches genuinely abandoned work rather than racing a slow one.
    STALE_AFTER = 10.minutes

    def self.call(...) = new(...).call

    def initialize(stale_after: STALE_AFTER, limit: 100)
      @stale_after = stale_after
      @limit = limit
    end

    def call
      swept = []

      stale_runs.each do |run|
        TenantScope.for_account(run.account) do
          abandoned = run.layer_results.where(state: "pending")
          if abandoned.any?
            Database::Retry.on_contention do
              abandoned.update_all(
                state: "timed_out",
                summary: "No response recorded before the run was swept as stale",
                completed_at: Time.current, updated_at: Time.current
              )
            end
          end

          # Hand it to the normal coordinator so finalisation goes through
          # exactly one code path, election and all.
          WaveCoordinator.new(run.reload).advance_from(2)
          swept << run.reload
        end
      end

      swept
    end

    private

    attr_reader :stale_after, :limit

    def stale_runs
      TenantScope.across_accounts do
        VerificationRun
          .where(status: VerificationRun::IN_FLIGHT_STATUSES)
          .where(created_at: ..stale_after.ago)
          .order(:created_at)
          .limit(limit)
          .to_a
      end
    end
  end
end
