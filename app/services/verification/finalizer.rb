module Verification
  # Turns a finished run into a verdict, a certificate, and - for accepted leads
  # - a CRM record.
  #
  # Rebuilds every layer's outcome from the database rather than from anything
  # held in memory, because the layers ran in separate jobs and possibly separate
  # processes. That is not a workaround: the database being the coordination
  # substrate is what makes the pipeline restartable.
  class Finalizer
    def self.call(...) = new(...).call

    def initialize(run:)
      @run = run
      @account = run.account
    end

    def call
      TenantScope.for_account(account) do
        verdict = Engine::Consensus.new(run.consensus_policy).call(run.engine_outcomes)

        run.update!(
          status: "completed",
          verdict: verdict.value,
          verdict_code: verdict.code,
          risk_score: verdict.risk,
          confidence_score: verdict.confidence,
          reasons: verdict.reasons.map { |r| r.transform_keys(&:to_s) },
          coverage_applicable: verdict.coverage[:expected],
          coverage_answered: verdict.coverage[:answered],
          completed_at: Time.current
        )

        certificate = Certificates::Issuer.call(run: run, verdict: verdict)
        Activity::Recorder.final_verdict(run, verdict)
        record_in_crm!(verdict)

        [ run, verdict, certificate ]
      end
    rescue StandardError => e
      Rails.logger.error("finalising run #{run.id} failed: #{e.class}: #{e.message}")
      # An errored run carries no verdict - the check constraint enforces that
      # independently - so it can never be mistaken for an approval.
      run.update!(status: "errored", verdict: nil, completed_at: Time.current)
      Activity::Recorder.run_errored(run, e)
      raise
    end

    private

    attr_reader :run, :account

    # Accepted leads are written into the buyer's CRM, which is what keeps
    # duplicate detection live rather than frozen at whatever the seed contained.
    # The second time the same person is accepted, the first acceptance is what
    # catches them.
    #
    # Only accepted leads. A rejected lead was never bought, so putting it in the
    # buyer's CRM would both misrepresent their book and cause the next
    # submission from that person to be rejected as a duplicate of a lead the
    # buyer never owned.
    def record_in_crm!(verdict)
      return unless verdict.accepted?

      lead = run.lead
      existing = CrmRecord.find_by(lead: lead)
      return existing if existing

      record = CrmRecord.create!(
        account: account, lead: lead,
        crm_id: "#{crm_prefix}-#{lead.public_id.delete_prefix('L-')}",
        first_name: lead.first_name, last_name: lead.last_name,
        email: lead.email, phone: lead.phone,
        recorded_at: Time.current, source: "accepted_lead"
      )
      Activity::Recorder.crm_record_created(record)
      record
    end

    def crm_prefix
      account.company_name.scan(/[A-Z]/).first(2).join.presence ||
        account.public_id.delete_prefix("acct_")[0, 2].upcase
    end
  end
end
