module Verification
  # Entry point for asynchronous verification. The pixel's ingestion endpoint
  # enqueues this and returns immediately, so the HTTP response the visitor's
  # browser is waiting on never blocks on a vendor call.
  class StartJob < ApplicationJob
    queue_as :verification

    def perform(lead_id)
      lead = TenantScope.across_accounts { Lead.find(lead_id) }

      TenantScope.for_account(lead.account) do
        Orchestrator.call(lead: lead)
      end
    end
  end
end
