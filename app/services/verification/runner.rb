module Verification
  # Runs a verification to completion in the current process.
  #
  # Used by db:seed, by the tests, and by `bin/rails leads:verify`. Deliberately
  # the SAME code path as the asynchronous one - it drives the identical
  # orchestrator, layer runner and coordinator, only with perform_now - so
  # nothing can pass synchronously and then behave differently under a worker.
  class Runner
    def self.call(lead:, policy: nil)
      Thread.current[:super_pixel_inline_verification] = true
      run = Orchestrator.new(lead: lead, policy: policy, perform_now: true).call
      run.reload
    ensure
      Thread.current[:super_pixel_inline_verification] = nil
    end
  end
end
