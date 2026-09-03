class ApplicationJob < ActiveJob::Base
  # A job starts with no tenant context, which is correct: it has not yet
  # learned which account it is working for. TenantScope.across_accounts is the
  # audited way to load the record that answers that, after which the job runs
  # inside a proper tenant scope for the rest of its work.
  #
  # Deserialization errors are discarded rather than retried: a record deleted
  # between enqueue and perform is not going to reappear.
  discard_on ActiveJob::DeserializationError

  private

  def load_run(run_id)
    TenantScope.across_accounts { VerificationRun.find(run_id) }
  end
end
