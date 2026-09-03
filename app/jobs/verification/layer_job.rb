module Verification
  # Runs one detection layer, then asks the coordinator whether that finished
  # its wave.
  #
  # One job per layer rather than one per wave, because vendor calls are
  # I/O-bound: eleven layers at ~300ms each is 3.3 seconds serially and closer to
  # 600ms in parallel, and for a pixel that has to feel live on a landing page
  # that difference is the whole product. The cost of the choice is a
  # coordination problem, solved in WaveCoordinator with a conditional status
  # update.
  #
  # Retries are safe: LayerRunner claims its row with a conditional UPDATE and
  # the credit charge is idempotent on its own key, so a retry of an already
  # completed layer is a no-op that cannot bill the buyer twice.
  class LayerJob < ApplicationJob
    queue_as :verification

    retry_on Providers::LayerUnavailable, wait: :polynomially_longer, attempts: 3
    retry_on ActiveRecord::StatementInvalid, wait: 2.seconds, attempts: 3

    def perform(run_id, module_key)
      run = load_run(run_id)
      return if run.completed? || run.halted?

      TenantScope.for_account(run.account) do
        result = LayerRunner.call(run: run, module_key: module_key)
        wave = result&.wave || run.layer_results.find_by(module_key: module_key)&.wave
        WaveCoordinator.new(run.reload, perform_now: inline?).layer_finished(wave) if wave
      end
    end

    private

    # When jobs are running inline (seeds, tests), keep the rest of the pipeline
    # inline too so one call completes the whole run.
    def inline?
      ActiveJob::Base.queue_adapter.class.name.include?("Inline") ||
        Thread.current[:super_pixel_inline_verification].present?
    end
  end
end
