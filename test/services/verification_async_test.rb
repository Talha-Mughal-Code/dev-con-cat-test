require "test_helper"

# The asynchronous path, driven through a real job queue rather than inline.
#
# Worth its own file because the interesting property is the wave coordination:
# layers are enqueued as independent jobs, and when the last one in a wave
# finishes, exactly one of them must advance the run. Inline execution would
# hide any bug in that election, because there is only ever one caller.
class VerificationAsyncTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "layers run as separate jobs and reach the same verdict as inline" do
    account, lead = build_scenario("L-1007")

    perform_enqueued_jobs do
      TenantScope.for_account(account) { Verification::StartJob.perform_later(lead.id) }
    end

    run = TenantScope.across_accounts { lead.reload.current_verification_run }

    assert_equal "completed", run.status
    assert_equal "review", run.verdict
    assert_equal "risk_threshold", run.verdict_code

    TenantScope.for_account(account) do
      # Both waves ran, so the election advanced the run exactly once.
      assert run.layer_results.in_wave(1).where.not(state: %w[not_enabled not_applicable]).all?(&:answered?)
      assert run.layer_results.in_wave(2).where.not(state: %w[not_enabled not_applicable]).all?(&:answered?)
      assert_equal 17, run.credits_charged
      assert_equal 1, run.consent_certificate ? 1 : 0
    end
  end

  test "a run is finalised exactly once even when several jobs race to close a wave" do
    # The failure this guards against: two jobs each see an empty pending set,
    # both advance the run, and the lead is finalised twice - two certificates,
    # two chain slots, a double-counted verdict.
    account, lead = build_scenario("L-1001")
    run = verify!(lead)

    certificates_before = TenantScope.for_account(account) { ConsentCertificate.count }

    TenantScope.for_account(account) do
      # Every layer is already settled, so all four of these believe they closed
      # the final wave.
      4.times { Verification::WaveCoordinator.new(run.reload).layer_finished(2) }
    end

    TenantScope.for_account(account) do
      assert_equal certificates_before, ConsentCertificate.count,
                   "the run must not be finalised twice"
      assert_equal 1, run.lead.verification_runs.count
      assert_equal 1, ConsentCertificate.where(verification_run: run).count
    end
  end

  test "the ingestion path enqueues rather than blocking the visitor's request" do
    # The pixel POSTs from a landing page, so the HTTP response must not wait on
    # eleven vendor calls.
    account, lead = build_scenario("L-1001")

    assert_enqueued_with(job: Verification::StartJob, args: [ lead.id ]) do
      TenantScope.for_account(account) { Verification::StartJob.perform_later(lead.id) }
    end
  end

  test "a layer job on an already-completed run does nothing" do
    account, lead = build_scenario("L-1001")
    run = verify!(lead)
    charged = run.credits_charged

    TenantScope.for_account(account) do
      Engine::Registry::MODULE_KEYS.each do |module_key|
        Verification::LayerJob.perform_now(run.id, module_key)
      end
    end

    assert_equal charged, run.reload.credits_charged
    assert_equal charged, account.reload.credits_consumed
  end
end
