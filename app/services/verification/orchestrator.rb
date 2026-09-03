module Verification
  # Creates a run and gets it moving.
  #
  # Everything after this point is driven by jobs (see WaveCoordinator), so this
  # class does exactly two things: write down what the run is going to be, and
  # enqueue wave 1.
  #
  # Writing every layer's row up front - including the ones that will never run -
  # is deliberate. It means the live panel can render the full layer list the
  # instant a lead arrives, and it means "not enabled" is a persisted fact rather
  # than something inferred later from an absence.
  class Orchestrator
    def self.call(...) = new(...).call

    def initialize(lead:, policy: nil, perform_now: false)
      @lead = lead
      @account = lead.account
      @policy = policy || @account.active_consensus_policy
      @perform_now = perform_now
    end

    def call
      run = nil

      TenantScope.for_account(account) do
        plans, budget = Planner.new(lead: lead, account: account, policy: policy).call

        # The run, its layer rows and the lead pointer are one logical write, so
        # they share one transaction - fewer lock acquisitions, and a run can
        # never exist without the rows describing what it planned to do.
        ActiveRecord::Base.transaction do
          run = VerificationRun.create!(
            lead: lead, consensus_policy: policy, status: "pending",
            credits_estimated: budget[:estimated],
            attempt: lead.verification_runs.count + 1,
            started_at: Time.current
          )
          create_layer_results!(run, plans)
          lead.update!(current_verification_run: run)
        end

        Activity::Recorder.run_started(run, planned: plans.map { |p| plan_summary(p) })

        if budget[:halt]
          # Out of credits before anything ran. No verdict, no certificate - the
          # platform makes no claim about this lead. See Halter for why this is
          # neither an accept nor a reject.
          Halter.call(run: run, shortfall: budget[:full_stack_cost] - budget[:available], ran: 0)
        else
          warn_if_credits_low
          start_first_wave(run)
        end
      end

      run
    end

    private

    attr_reader :lead, :account, :policy, :perform_now

    # One transaction for all eleven rows rather than one each. Under SQLite's
    # single writer that is the difference between eleven queued lock
    # acquisitions and one - and with several leads arriving at once, it is the
    # difference between an ingestion endpoint that responds in tens of
    # milliseconds and one that stalls for seconds.
    def create_layer_results!(run, plans)
      ActiveRecord::Base.transaction do
        plans.each do |plan|
          create_layer_result!(run, plan)
        end
      end
    end

    def create_layer_result!(run, plan)
      run.layer_results.create!(
        account: account, detection_module: plan.detection_module,
        module_key: plan.module_key, state: plan.state, wave: plan.wave,
        summary: silent_summary(plan)
      )
    end

    # A blank row invites the reader to assume a pass, so every layer that will
    # not run says why in words - on screen and on the certificate alike.
    def silent_summary(plan)
      case plan.state
      when "not_enabled"
        "Not checked - #{plan.detection_module.name} is not enabled for #{account.company_name}"
      when "not_applicable"
        "Does not apply to this lead"
      when "skipped_insufficient_credits"
        "Not run - account is out of credits"
      end
    end

    def plan_summary(plan)
      { module_key: plan.module_key, name: plan.detection_module.name,
        state: plan.state, wave: plan.wave, cost: plan.cost, runnable: plan.runnable }
    end

    def start_first_wave(run)
      first_wave = run.layer_results.in_wave(1).where(state: "pending")
      # An account whose whole stack sits in wave 2 would otherwise stall here.
      return WaveCoordinator.new(run).advance_from(0) if first_wave.empty?

      Database::Retry.on_contention { run.update!(status: "wave_1") }
      enqueue(run, first_wave.pluck(:module_key))
    end

    def enqueue(run, module_keys)
      module_keys.each do |module_key|
        if perform_now
          # Used by the seeds and by tests: identical code path, no worker
          # required.
          LayerJob.perform_now(run.id, module_key)
        else
          LayerJob.perform_later(run.id, module_key)
        end
      end
    end

    # Warn while the buyer can still act on it, and warn once per run rather
    # than once per layer.
    def warn_if_credits_low
      health = account.credit_health
      return if health == :healthy

      if health == :exhausted
        Activity::Recorder.credits_exhausted(account)
      else
        Activity::Recorder.credits_low(account)
      end
    end
  end
end
