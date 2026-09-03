module Activity
  # Writes to the single append-only stream that serves the account timeline, the
  # audit trail, and the real-time feed the landing page tails.
  #
  # One writer for all three because they are the same facts viewed differently.
  # The alternative - a timeline table plus a broadcast - means two things that
  # can disagree, and the one the buyer would rely on in a dispute is the one
  # least likely to be reconciled.
  class Recorder
    class << self
      def record!(kind:, account:, lead: nil, verification_run: nil, capture_session: nil,
                  pixel: nil, **payload)
        account ||= lead&.account || verification_run&.account

        TenantScope.for_account(account) do
          ActivityEvent.create!(
            account: account, lead: lead, verification_run: verification_run,
            capture_session: capture_session, pixel: pixel || lead&.pixel,
            kind: kind.to_s, payload: payload.deep_stringify_keys,
            occurred_at: Time.current
          )
        end
      end

      def session_started(session)
        record!(kind: "session_started", account: session.account, capture_session: session,
                pixel: session.pixel, headline: "Capture session opened",
                page_url: session.page_url, visit_ip: session.visit_ip)
      end

      def lead_received(lead)
        record!(kind: "lead_received", account: lead.account, lead: lead,
                headline: "Lead received", lead_id: lead.public_id,
                form_dwell_ms: lead.form_dwell_ms)
      end

      def run_started(run, planned:)
        record!(kind: "run_started", account: run.account, lead: run.lead, verification_run: run,
                headline: "Running #{planned.count { |p| p[:runnable] }} detection layers",
                lead_id: run.lead.public_id, planned: planned,
                credits_estimated: run.credits_estimated)
      end

      # The event the live panel renders as one row. Field names match
      # docs/pixel-spec.md's contract so the reference landing page needed no
      # change to its rendering code.
      def layer_result(result)
        record!(
          kind: "layer_result", account: result.account, lead: result.verification_run.lead,
          verification_run: result.verification_run,
          layer: result.module_key, name: result.display_name,
          verdict: result.display_status, detail: result.summary,
          state: result.state, signal: result.signal,
          hard_stop: result.hard_stop, risk_contribution: result.risk_contribution.round(4),
          credits_charged: result.credits_charged, latency_ms: result.latency_ms
        )
      end

      def final_verdict(run, verdict)
        record!(
          kind: "final_verdict", account: run.account, lead: run.lead, verification_run: run,
          headline: "Verdict: #{verdict.value.upcase}",
          verdict: verdict.value.upcase, code: verdict.code,
          # The page renders `score` as a percentage; confidence is the figure a
          # buyer actually wants there ("how sure are we this lead is good").
          score: verdict.confidence, risk: verdict.risk,
          reasons: verdict.reasons.map { |r| r[:message] },
          coverage: verdict.coverage.transform_keys(&:to_s),
          credits_charged: run.credits_charged
        )
      end

      def certificate_issued(certificate)
        record!(kind: "certificate_issued", account: certificate.account,
                lead: certificate.lead, verification_run: certificate.verification_run,
                headline: "Consent certificate #{certificate.serial} issued",
                serial: certificate.serial, digest: certificate.content_digest)
      end

      def run_halted(run, shortfall:, ran:)
        record!(
          kind: "run_halted", account: run.account, lead: run.lead, verification_run: run,
          headline: "Verification halted - out of credits",
          verdict: "HALTED", code: "insufficient_credits",
          detail: "#{run.account.public_id} needs #{shortfall} more credits. " \
                  "#{ran} #{'layer'.pluralize(ran)} ran; no verdict was issued.",
          reasons: [ "Account has #{run.account.credits_remaining} credits remaining" ]
        )
      end

      def run_errored(run, error)
        record!(kind: "run_errored", account: run.account, lead: run.lead, verification_run: run,
                headline: "Verification errored", verdict: "ERRORED",
                code: "internal_error", detail: error.class.name,
                reasons: [ error.message ])
      end

      def credits_low(account)
        record!(kind: "credits_low", account: account,
                headline: "Credit balance #{account.credit_health}",
                remaining: account.credits_remaining,
                days_until_dry: account.days_until_dry,
                health: account.credit_health.to_s)
      end

      def credits_exhausted(account)
        record!(kind: "credits_exhausted", account: account,
                headline: "Credits exhausted", remaining: account.credits_remaining)
      end

      def crm_record_created(record)
        record!(kind: "crm_record_created", account: record.account, lead: record.lead,
                headline: "Written to CRM as #{record.crm_id}", crm_id: record.crm_id)
      end
    end
  end
end
