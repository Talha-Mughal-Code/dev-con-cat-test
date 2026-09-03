require "test_helper"

# End-to-end tests for the pipeline: planning, wave execution, credit charging,
# short-circuiting, and the three layer states as they land in the database.
#
# These run the identical orchestrator, layer runner, coordinator and finaliser
# the asynchronous path uses, only inline - so nothing can pass here and behave
# differently under a worker.
class VerificationPipelineTest < ActiveSupport::TestCase
  test "a clean lead is accepted, charged per answered layer, and certified" do
    account, lead = build_scenario("L-1001")

    run = verify!(lead)

    assert_equal "completed", run.status
    assert_equal "accept", run.verdict
    assert_equal "clean", run.verdict_code
    assert_in_delta 0.0, run.risk_score, 0.0001

    TenantScope.for_account(account) do
      # Charged the sum of the layers that actually answered, and nothing else.
      answered = run.layer_results.answered
      assert_equal answered.sum(:credits_charged), run.credits_charged
      assert_equal 17, run.credits_charged
      assert_equal 17, account.reload.credits_consumed

      # Every layer has a row, including the one this account has not bought.
      assert_equal Engine::Registry::MODULE_KEYS.size, run.layer_results.count
      voice = run.layer_results.find_by(module_key: "voice")
      assert_equal "not_enabled", voice.state
      assert_nil voice.signal, "a layer nobody paid for must never carry a signal"
      assert_equal 0, voice.credits_charged
      assert_match(/not enabled/i, voice.summary)

      assert run.consent_certificate.present?
      assert run.consent_certificate.verify.valid?
    end
  end

  test "a hard stop short-circuits the expensive wave and saves the buyer credits" do
    account, lead = build_scenario("L-1002")

    run = verify!(lead)

    assert_equal "reject", run.verdict
    assert_equal "bot_confirmed", run.verdict_code
    assert run.short_circuited?

    TenantScope.for_account(account) do
      skipped = run.layer_results.where(state: "skipped_hard_stop")
      assert skipped.any?, "wave 2 should not have run"
      assert_equal 0, skipped.sum(:credits_charged)
      # Wave 1 only: 7 credits rather than the 17 a full stack would cost.
      assert_equal 7, run.credits_charged
      # Nothing failed, so the deliberate saving is not held against coverage -
      # but it is named.
      assert_equal skipped.pluck(:module_key).sort,
                   run.layer_results.where(state: "skipped_hard_stop").pluck(:module_key).sort
    end
  end

  test "a buyer can turn short-circuiting off and pay for the full evidence file" do
    account, lead = build_scenario("L-1002")
    account.update!(short_circuit_on_hard_stop: false)

    run = verify!(lead)

    assert_equal "reject", run.verdict
    assert_not run.short_circuited?
    TenantScope.for_account(account) do
      assert_equal 0, run.layer_results.where(state: "skipped_hard_stop").count
      assert_equal 17, run.credits_charged, "the full stack was requested and charged for"
    end
  end

  test "a layer that does not apply is recorded as such and never charged" do
    # Voice on a lead with no sample - the brief's own example.
    account, lead = build_scenario("L-1003", modules: Engine::Registry::MODULE_KEYS)

    run = verify!(lead)

    TenantScope.for_account(account) do
      voice = run.layer_results.find_by(module_key: "voice")
      assert_equal "not_applicable", voice.state
      assert_nil voice.signal
      assert_equal 0, voice.credits_charged, "5 credits to be told there is no voice sample"
      assert_equal "Does not apply to this lead", voice.summary
    end
  end

  test "an unavailable consent layer is recorded, uncharged, and caps the verdict" do
    account, lead = build_scenario("L-1001")

    run = Providers::Gateway.with_outages("trustedform") { verify!(lead) }

    TenantScope.for_account(account) do
      trustedform = run.layer_results.find_by(module_key: "trustedform")
      assert_equal "errored", trustedform.state
      assert_nil trustedform.signal
      assert_equal 0, trustedform.credits_charged, "we do not bill for our own outage"
      assert_match(/unavailable/i, trustedform.summary)

      # Everything else passed, so this is purely the fail-closed rule.
      assert_equal "review", run.verdict
      assert_equal "fail_closed_layer_unavailable", run.verdict_code
      assert_in_delta 0.0, run.risk_score, 0.0001
    end
  end

  test "an unavailable non-critical layer fails open and still accepts" do
    account, lead = build_scenario("L-1001")

    run = Providers::Gateway.with_outages("enrichment") { verify!(lead) }

    assert_equal "accept", run.verdict
    TenantScope.for_account(account) do
      assert_equal "errored", run.layer_results.find_by(module_key: "enrichment").state
      assert_equal 13, run.credits_charged, "the 4 credits for enrichment were not charged"
    end
  end

  test "an accepted lead is written into the buyer's CRM" do
    # Which is what keeps duplicate detection live rather than frozen at seed.
    account, lead = build_scenario("L-1001")

    verify!(lead)

    TenantScope.for_account(account) do
      record = CrmRecord.find_by(lead: lead)
      assert record.present?
      assert_equal "accepted_lead", record.source
      assert_equal lead.phone_normalized, record.phone_normalized
    end
  end

  test "a rejected lead is never written into the buyer's CRM" do
    # It was not bought. Recording it would misrepresent the buyer's book and
    # cause the next submission from that person to be rejected as a duplicate
    # of a lead the buyer never owned.
    account, lead = build_scenario("L-1002")

    verify!(lead)

    TenantScope.for_account(account) do
      assert_nil CrmRecord.find_by(lead: lead)
    end
  end

  test "the same person submitted twice is caught by the first acceptance" do
    account, lead = build_scenario("L-1001")
    verify!(lead)

    second = build_lead(account: account, pixel: lead.pixel, first_name: lead.first_name,
                        last_name: lead.last_name, email: lead.email, phone: lead.phone,
                        landing_page_url: lead.landing_page_url, form_dwell_ms: 40_000,
                        captured_at: 1.minute.from_now)

    run = verify!(second)

    assert_equal "reject", run.verdict
    assert_equal "duplicate_hard", run.verdict_code
  end

  test "running out of credits before any layer runs halts with no verdict" do
    # The central decision: a halted run is neither an accept nor a reject.
    # Accepting would vouch for a lead we did not check; rejecting would destroy
    # a possibly-good lead over a billing problem.
    account, lead = build_scenario("L-1001", allowance: 3)

    run = verify!(lead)

    assert_equal "halted_insufficient_credits", run.status
    assert_nil run.verdict, "a halted run must make no claim about the lead"
    assert_equal "HALTED - NO CREDITS", run.verdict_label

    TenantScope.for_account(account) do
      assert_nil run.consent_certificate, "no certificate for a lead we did not finish checking"
      assert run.layer_results.where(state: "skipped_insufficient_credits").any?
      assert_equal 0, run.credits_charged
      assert_equal 3, account.reload.credits_remaining, "nothing was spent"
    end
  end

  test "a database constraint independently forbids a verdict on a halted run" do
    # Belt and braces: even a future code path that tried to write an accept onto
    # a halted run is refused by the database.
    _account, lead = build_scenario("L-1001", allowance: 3)
    run = verify!(lead)

    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.connection.execute(
        "UPDATE verification_runs SET verdict = 'accept' WHERE id = #{run.id}"
      )
    end
  end

  test "a partial budget funds the dispositive layers first" do
    # 8 credits buys all of wave 1 (7) plus the cheapest wave-2 layer. Wave 1 is
    # funded first because those are the layers that can reject a lead outright,
    # so they are worth strictly more per credit than ones that only shade a
    # score.
    account, lead = build_scenario("L-1001", allowance: 8)

    run = verify!(lead)

    TenantScope.for_account(account) do
      assert_equal "completed", run.status

      wave_one = run.layer_results.in_wave(1).where.not(state: %w[not_enabled not_applicable])
      assert wave_one.all?(&:answered?), "every dispositive check should have run"

      skipped = run.layer_results.where(state: "skipped_insufficient_credits")
      assert skipped.any?, "the expensive wave-2 layers should have been skipped"
      assert_equal 0, skipped.sum(:credits_charged)
      assert_operator run.credits_charged, :<=, 8
      assert_equal 0, account.reload.credits_remaining

      # Every dispositive check ran and coverage still clears the floor, so a
      # verdict is defensible - but the shortfall is stated in the reasons,
      # because this buyer did not get the check they normally get.
      assert_equal "accept", run.verdict
      assert_operator run.coverage_ratio, :>=, run.consensus_policy.coverage_floor
      note = run.reasons.find { |r| r["code"] == "skipped_for_credits" }
      assert note.present?, "an incomplete check must say so: #{run.reasons.inspect}"
      assert_match(/out of credits/, note["message"])
    end
  end

  test "the certificate names the layers that credits could not pay for" do
    account, lead = build_scenario("L-1001", allowance: 8)
    run = verify!(lead)

    TenantScope.for_account(account) do
      coverage = run.consent_certificate.payload.fetch("coverage")
      assert coverage.fetch("skipped_for_credits").any?
      assert_equal run.layer_results.where(state: "skipped_insufficient_credits")
                      .pluck(:module_key).sort,
                   coverage.fetch("skipped_for_credits").sort
    end
  end

  test "re-running a lead creates a new run and leaves the first intact" do
    # The reason a run is a separate entity from the lead.
    account, lead = build_scenario("L-1001")
    first = verify!(lead)
    first_certificate = TenantScope.for_account(account) { first.consent_certificate }

    second = verify!(lead.reload)

    assert_not_equal first.id, second.id
    assert_equal 1, first.attempt
    assert_equal 2, second.attempt
    assert_equal second.id, lead.reload.current_verification_run_id

    TenantScope.for_account(account) do
      assert_equal "completed", first.reload.status, "history is preserved"
      assert first_certificate.reload.verify.valid?, "the earlier certificate stays valid"
      assert_equal 2, lead.verification_runs.count
    end
  end

  test "a retried layer job neither reruns the vendor nor recharges the buyer" do
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    charged_before = run.credits_charged
    consumed_before = account.reload.credits_consumed

    TenantScope.for_account(account) do
      # Exactly what Solid Queue does after a transient failure.
      Verification::LayerJob.perform_now(run.id, "phone_validation")
      Verification::LayerJob.perform_now(run.id, "anura")
    end

    assert_equal charged_before, run.reload.credits_charged
    assert_equal consumed_before, account.reload.credits_consumed
  end

  test "the activity stream records the run in order" do
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    TenantScope.for_account(account) do
      events = ActivityEvent.where(lead: lead).chronological
      kinds = events.map(&:kind)

      assert_equal "run_started", kinds.first
      assert_equal "final_verdict", kinds[-2..].first
      assert_includes kinds, "certificate_issued"
      # One event per layer that ran, so the live panel gets a row for each.
      assert_equal run.layer_results.answered.count, kinds.count("layer_result")

      # Ids are monotonic, which is what makes them usable as an SSE cursor.
      assert_equal events.map(&:id).sort, events.map(&:id)
    end
  end

  test "layer results carry the evidence the certificate and UI need" do
    account, lead = build_scenario("L-1007")

    run = verify!(lead)

    TenantScope.for_account(account) do
      phone = run.layer_results.find_by(module_key: "phone_validation")
      assert_equal "warn", phone.signal
      assert_operator phone.risk_contribution, :>, 0
      # The raw vendor response is retained as evidence...
      assert phone.payload["providers"].present?
      # ...alongside our own reading of what they agreed on.
      assert_equal %w[twilio_lookup telesign], phone.breakdown.dig("agreement", "valid")
      assert_equal [ "numverify" ], phone.breakdown.dig("agreement", "invalid")
      assert phone.findings.any?
      assert phone.latency_ms.present?
    end
  end

  # --- abandoned runs -------------------------------------------------------

  test "a run abandoned mid-flight is swept to a defensible verdict, not left hanging" do
    # Found by load testing: a layer job can exhaust its retries under heavy
    # write contention, leaving the run in wave_1 forever - no verdict, no
    # certificate, and a lead the buyer paid to capture that nobody decides on.
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    # Rewind it into the state an abandoned run is in.
    TenantScope.for_account(account) do
      run.layer_results.where(module_key: %w[phone_validation enrichment])
         .update_all(state: "pending", signal: nil, credits_charged: 0)
      run.update_columns(status: "wave_2", verdict: nil, verdict_code: nil,
                         completed_at: nil, created_at: 30.minutes.ago)
      run.consent_certificate&.delete
    end

    swept = Verification::StaleRunSweeper.call

    assert_equal [ run.id ], swept.map(&:id)
    run.reload
    assert_equal "completed", run.status
    assert run.verdict.present?, "a swept run must reach a verdict it can defend"

    TenantScope.for_account(account) do
      # The layers that never answered say so - truthfully - and feed the normal
      # fail-open / fail-closed handling rather than inventing new behaviour.
      assert_equal 2, run.layer_results.where(state: "timed_out").count
      assert_equal 0, run.layer_results.where(state: "pending").count
      assert run.consent_certificate.present?
    end
  end

  test "the sweeper leaves a run that is merely young alone" do
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    TenantScope.for_account(account) do
      run.update_columns(status: "wave_2", verdict: nil, verdict_code: nil,
                         completed_at: nil, created_at: 1.minute.ago)
    end

    assert_empty Verification::StaleRunSweeper.call
    assert_equal "wave_2", run.reload.status
  end

  test "a swept run cannot silently accept a lead most of whose layers never ran" do
    # The rule that makes sweeping safe: it finalises on the evidence that
    # arrived, and thin evidence cannot produce an ACCEPT.
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    TenantScope.for_account(account) do
      # Only the cheap first-party layer ever answered.
      run.layer_results.where.not(module_key: "capture_behaviour")
         .where(state: "completed")
         .update_all(state: "pending", signal: nil, credits_charged: 0)
      run.update_columns(status: "wave_1", verdict: nil, verdict_code: nil,
                         completed_at: nil, created_at: 30.minutes.ago)
      run.consent_certificate&.delete
    end

    Verification::StaleRunSweeper.call

    assert_equal "review", run.reload.verdict
    assert_includes %w[fail_closed_layer_unavailable insufficient_coverage], run.verdict_code
  end
end
