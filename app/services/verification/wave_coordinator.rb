module Verification
  # Decides what happens when a wave finishes.
  #
  # THE CONCURRENCY PROBLEM
  # Layers run as independent parallel jobs, so when the last one in a wave
  # completes, several jobs may each look around and conclude the wave is over.
  # Exactly one of them must advance the run, or wave 2 gets enqueued twice and
  # the lead is finalised twice.
  #
  # The solution uses the status column that already had to exist, as the lock:
  #
  #     UPDATE verification_runs SET status = 'wave_2' WHERE id = ? AND status = 'wave_1'
  #
  # One row affected means this job won the election and owns what happens next;
  # zero means another job already did it. No advisory locks, no extra table, no
  # dependency on a queue's uniqueness guarantees - just a conditional write,
  # which is the one primitive every database gives you.
  #
  # SHORT-CIRCUITING
  # If a wave-1 layer produced an armed hard stop, wave 2 never runs. The lead is
  # already dispositively rejected, so the expensive layers would cost the buyer
  # credits to tell them something that cannot change the outcome. For the three
  # accounts in the fixtures that saves 9-15 credits on every rejected lead.
  # Tunable per account via accounts.short_circuit_on_hard_stop for a buyer who
  # would rather have the complete evidence file.
  class WaveCoordinator
    WAVES = [ 1, 2 ].freeze
    # The only statuses a run may be advanced out of. Naming them explicitly is
    # what makes the election safe: a run that is already finalizing, completed,
    # halted or errored matches nothing, so a late or duplicate job cannot
    # reopen it.
    ADVANCEABLE = %w[pending wave_1 wave_2].freeze

    def initialize(run, perform_now: false)
      @run = run
      @perform_now = perform_now
    end

    # Called by a layer job once its own row is written.
    def layer_finished(wave)
      return unless wave_settled?(wave)

      advance_from(wave)
    end

    def advance_from(finished_wave)
      # A settled run is done being coordinated. Without this, a duplicate job
      # would try to move a completed run back to 'finalizing' - and the
      # database would refuse it, because a verdict may only exist on a
      # completed run. Better to decline here than to rely on the constraint.
      return if run.reload.status.in?(%w[finalizing completed halted_insufficient_credits errored])

      TenantScope.for_account(run.account) do
        next_wave = WAVES.find { |w| w > finished_wave && pending_in_wave(w).any? }

        if next_wave.nil? || short_circuit?
          skip_remaining_layers! if next_wave.present?
          finalize!
        else
          enter_wave(next_wave)
        end
      end
    end

    private

    attr_reader :run, :perform_now

    def wave_settled?(wave)
      pending_in_wave(wave).none?
    end

    def pending_in_wave(wave)
      run.layer_results.in_wave(wave).where(state: "pending")
    end

    # Elect one job to advance the run. Exactly one caller can move the row out
    # of an advanceable status, and that caller owns what happens next.
    def claim(to:)
      Database::Retry.on_contention do
        VerificationRun.where(id: run.id, status: ADVANCEABLE)
                       .update_all(status: to, updated_at: Time.current) == 1
      end
    end

    def enter_wave(wave)
      return unless claim(to: "wave_#{wave}")

      keys = pending_in_wave(wave).pluck(:module_key)
      keys.each do |module_key|
        if perform_now
          LayerJob.perform_now(run.id, module_key)
        else
          LayerJob.perform_later(run.id, module_key)
        end
      end
    end

    def finalize!
      return unless claim(to: "finalizing")

      Finalizer.call(run: run.reload)
    end

    def short_circuit?
      return false unless run.account.short_circuit_on_hard_stop?

      run.layer_results.where(hard_stop: true, state: "completed").exists?
    end

    def skip_remaining_layers!
      skipped = run.layer_results.where(state: "pending")
      names = skipped.pluck(:module_key)
      return if names.empty?

      Database::Retry.on_contention do
        skipped.update_all(
          state: "skipped_hard_stop",
          summary: "Not run: the lead was already rejected by a dispositive check, " \
                   "so these credits were not spent",
          completed_at: Time.current, updated_at: Time.current
        )
        run.update!(short_circuited: true)
      end

      saved = run.account.enabled_module_costs.slice(*names).values.sum
      Activity::Recorder.record!(
        kind: "layer_result", account: run.account, lead: run.lead, verification_run: run,
        layer: "consensus", name: "Short circuit", verdict: "skipped",
        detail: "Hard stop reached - skipped #{names.size} remaining " \
                "#{'layer'.pluralize(names.size)} and saved #{saved} credits"
      )
    end
  end
end
