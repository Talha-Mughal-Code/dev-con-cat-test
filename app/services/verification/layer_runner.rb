module Verification
  # Executes one layer: fetch, translate, price, charge, record.
  #
  # Idempotent by design, because Solid Queue will retry. The row is claimed with
  # a conditional UPDATE, so a retry of a layer that already completed does
  # nothing at all - and the credit charge behind it is separately idempotent on
  # its own key, so even a crash between charging and writing the row cannot bill
  # the buyer twice.
  #
  # ORDER OF OPERATIONS
  # The vendor is called first and charged for afterwards, and only if it
  # answered. Charging first would bill the buyer for our own outages; charging
  # for an errored layer would do the same more quietly.
  class LayerRunner
    def self.call(...) = new(...).call

    def initialize(run:, module_key:)
      @run = run
      @module_key = module_key.to_s
      @account = run.account
    end

    def call
      result = claim_result
      # Already done, or never meant to run. Either way there is nothing to do,
      # which is what makes a retry safe.
      return nil if result.nil?

      started = Time.current
      begin
        payload = gateway.fetch(module_key)
        assessment = evaluator.call(payload, lead_context)
        resolution = consensus.resolve_layer(outcome_for(assessment))

        charge = charge_for_layer(result)

        write! do
          result.update!(
            state: "completed",
            signal: resolution[:signal],
            hard_stop: resolution[:hard_stops].any?,
            risk_contribution: resolution[:risk],
            summary: assessment.summary,
            payload: payload,
            breakdown: assessment.breakdown,
            findings: assessment.findings.map { |f| serialise(f) },
            credits_charged: charge,
            latency_ms: elapsed_ms(started),
              started_at: started, completed_at: Time.current
          )
        end
      rescue Providers::LayerUnavailable => e
        # The layer is enabled and applicable but could not answer. Recorded as a
        # distinct state so the policy's fail-open / fail-closed handling can act
        # on it - and explicitly not charged for.
        result.update!(
          state: "errored", error_class: e.class.name, error_message: e.message,
          summary: "Provider unavailable: #{e.message}", credits_charged: 0,
          latency_ms: elapsed_ms(started), started_at: started, completed_at: Time.current
        )
      rescue Credits::InsufficientCredits => e
        # The balance moved between planning and execution - another run for the
        # same account spent it. The layer did not run and is not charged for.
        result.update!(
          state: "skipped_insufficient_credits", error_class: e.class.name,
          error_message: e.message, credits_charged: 0,
          summary: "Skipped: #{e.shortfall} more credits needed",
          latency_ms: elapsed_ms(started), started_at: started, completed_at: Time.current
        )
      rescue StandardError => e
        # A transient database lock is NOT a failed layer. Re-raised so the job
        # retries, because recording it as errored would let a moment of write
        # contention downgrade a perfectly good lead through the fail-closed
        # rule. This distinction is the whole reason the rescue is not blanket.
        raise if Database::Retry.contention?(e)

        # Anything else genuinely is an unanswered layer rather than a crashed
        # run. Recorded, reported, and left to the same fail-open / fail-closed
        # treatment as a vendor outage.
        Rails.logger.error("layer #{module_key} failed for run #{run.id}: #{e.class}: #{e.message}")
        write! do
          result.update!(
            state: "errored", error_class: e.class.name, error_message: e.message,
            summary: "Layer failed: #{e.class}", credits_charged: 0,
            latency_ms: elapsed_ms(started), started_at: started, completed_at: Time.current
          )
        end
      end

      write! { run.increment!(:credits_charged, result.credits_charged) } if result.credits_charged.positive?
      Activity::Recorder.layer_result(result)
      result
    end

    private

    attr_reader :run, :module_key, :account

    def write!(&block)
      Database::Retry.on_contention(&block)
    end

    # Conditional claim: only a row still pending is taken, and taking it is a
    # single UPDATE. Two workers racing on the same layer cannot both proceed.
    def claim_result
      claimed = write! do
        run.layer_results
           .where(module_key: module_key, state: "pending")
           .update_all(state: "pending", started_at: Time.current, updated_at: Time.current)
      end
      return nil if claimed.zero?

      run.layer_results.find_by(module_key: module_key)
    end

    def charge_for_layer(result)
      cost = cost_for(result)
      return 0 if cost.zero?

      entry = Credits::Ledger.charge!(
        account: account, amount: cost, module_key: module_key,
        verification_run: run, layer_result: result,
        # Stable across retries and unique per (run, layer). This is the whole
        # double-charge defence.
        idempotency_key: "run:#{run.id}:module:#{module_key}",
        description: "#{result.display_name} check for #{run.lead.public_id}"
      )
      entry ? entry.credits : 0
    end

    def cost_for(result)
      account.enabled_module_costs.fetch(module_key, result.detection_module.default_cost_in_credits)
    end

    def gateway
      @gateway ||= Providers::Gateway.new(lead: run.lead, capture_session: run.lead.capture_session)
    end

    def evaluator = @evaluator ||= Engine::Registry.for(module_key)

    def lead_context = @lead_context ||= Engine::LeadContext.from(run.lead)

    def consensus = @consensus ||= Engine::Consensus.new(run.consensus_policy)

    def outcome_for(assessment)
      Engine::LayerOutcome.new(
        module_key: module_key, state: "completed", assessment: assessment,
        fail_closed: false
      )
    end

    def serialise(finding)
      { "module_key" => finding.module_key, "hard_stop_code" => finding.hard_stop_code,
        "weight_key" => finding.weight_key, "detail" => finding.detail,
        "advisory" => finding.advisory? }
    end

    def elapsed_ms(started) = ((Time.current - started) * 1000).round
  end
end
