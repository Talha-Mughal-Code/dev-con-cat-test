module Certificates
  # Issues the consent certificate for a completed run.
  #
  # WHAT GOES IN, AND WHY
  # The test applied to every field: would a buyer's counsel, holding only this
  # document eighteen months from now, be able to answer "on what basis did you
  # call this person?" So the certificate carries not just the verdict but the
  # evidence behind it - who was checked, by which layers, with what result, on
  # what page, with which retained TrustedForm reference, and crucially which
  # layers did NOT run and why.
  #
  # That last part is what makes it honest. A certificate that lists nine passing
  # layers and silently omits the two the buyer never subscribed to is a
  # misleading document, and the one place where conflating "not enabled" with
  # "passed" would cause real harm.
  #
  # A certificate is issued for every completed run, rejections included: a buyer
  # who declines a lead needs evidence of why just as much, whether the argument
  # is with a regulator or with the seller who invoiced them for it.
  class Issuer
    def self.call(...) = new(...).call

    def initialize(run:, verdict:)
      @run = run
      @verdict = verdict
      @lead = run.lead
      @account = run.account
    end

    def call
      TenantScope.for_account(account) do
        # One certificate per run. If a retry gets this far, hand back the one
        # already issued rather than forking the account's hash chain.
        existing = ConsentCertificate.find_by(verification_run: run)
        next existing if existing

        issue!
      end
    end

    private

    attr_reader :run, :verdict, :lead, :account

    def issue!
      serial = generate_serial
      previous = ConsentCertificate.where(account: account).order(chain_index: :desc).first
      chain_index = (previous&.chain_index || -1) + 1
      issued_at = Time.current

      # Normalise BEFORE storing, not just before hashing. The column holds JSON,
      # so a Time written raw would come back as a differently-formatted string
      # and the recomputed digest would never match - the certificate would
      # verify as tampered the moment it was read back. Storing the canonical
      # form makes the digest a function of exactly what is on disk.
      payload = Canonical.normalize(
        build_payload(serial: serial, issued_at: issued_at,
                      chain_index: chain_index, prev_digest: previous&.content_digest)
      )
      digest = Canonical.digest(payload)
      signer = Signer.instance

      certificate = ConsentCertificate.create!(
        verification_run: run, lead: lead, account: account,
        serial: serial, schema_version: ConsentCertificate::SCHEMA_VERSION,
        issued_at: issued_at, payload: payload, content_digest: digest,
        prev_digest: previous&.content_digest, chain_index: chain_index,
        signature: signer.sign(digest), key_id: signer.key_id, algorithm: signer.algorithm
      )

      Activity::Recorder.certificate_issued(certificate)
      certificate
    rescue ActiveRecord::RecordNotUnique
      # Lost a race for the same chain slot. The other writer's certificate is
      # equally valid, so use it.
      ConsentCertificate.find_by(verification_run: run) || raise
    end

    # Human-legible and unguessable. The random half matters because the serial
    # is the credential for public verification.
    def generate_serial
      "SPC-#{Time.current.utc.strftime('%Y%m')}-#{SecureRandom.alphanumeric(12).upcase}"
    end

    def build_payload(serial:, issued_at:, chain_index:, prev_digest:)
      {
        "schema_version" => ConsentCertificate::SCHEMA_VERSION,
        "serial" => serial,
        "issued_at" => issued_at,
        "issuer" => "Super Pixel consent platform",
        "chain" => { "index" => chain_index, "prev_digest" => prev_digest },

        "account" => {
          "public_id" => account.public_id,
          "company_name" => account.company_name
        },
        "pixel" => lead.pixel && {
          "public_id" => lead.pixel.public_id,
          "name" => lead.pixel.name
        },

        "lead" => {
          "public_id" => lead.public_id,
          "first_name" => lead.first_name,
          "last_name" => lead.last_name,
          "email" => lead.email,
          "phone" => lead.phone,
          "captured_at" => lead.captured_at,
          "submitted_at" => lead.submitted_at,
          "campaign" => lead.campaign
        },

        # The consent story: what was claimed, and what verified it.
        "consent" => consent_evidence,

        # How the form was filled. Not a vendor's opinion - our own first-party
        # observation, and often the most persuasive part of a TCPA defence.
        "capture_evidence" => capture_evidence,

        # Every layer, including the silent ones, with the reason for its
        # silence.
        "layers" => run.layer_results.ordered.map(&:to_certificate_entry),
        "coverage" => coverage_statement,

        "verdict" => verdict.to_h_for_storage,
        "policy" => run.consensus_policy.descriptor,

        "billing" => {
          "credits_charged" => run.credits_charged,
          "per_layer" => run.layer_results.answered.to_h { |r| [ r.module_key, r.credits_charged ] }
        }
      }.compact
    end

    def consent_evidence
      trustedform = run.layer_results.find_by(module_key: "trustedform")
      evidence = {
        "trusted_form_cert_url" => lead.trusted_form_cert_url,
        "checkbox_captured" => !lead.consent_checkbox.nil?,
        "checkbox_ticked" => lead.consent_checkbox,
        "landing_page_url" => lead.landing_page_url
      }

      if trustedform&.answered?
        evidence.merge!(
          "trusted_form_state" => trustedform.state,
          "trusted_form_verified" => trustedform.signal == "pass",
          "trusted_form_detail" => trustedform.summary,
          "trusted_form_evidence" => trustedform.breakdown
        )
      elsif trustedform
        # Says plainly that the consent layer did not speak, and why.
        evidence["trusted_form_state"] = trustedform.state
        evidence["trusted_form_detail"] = trustedform.summary ||
                                          "TrustedForm was #{trustedform.state.humanize.downcase}"
      end

      evidence.compact
    end

    def capture_evidence
      session = lead.capture_session
      {
        "landing_page_url" => lead.landing_page_url,
        "submit_ip" => lead.ip_address,
        "user_agent" => lead.user_agent,
        "form_dwell_ms" => lead.form_dwell_ms,
        "visit_ip" => session&.visit_ip,
        "ip_consistent_between_visit_and_submit" => session&.ip_consistent?,
        "referrer" => session&.referrer,
        "session_started_at" => session&.started_at,
        "field_interactions" => session&.interaction_summary&.stringify_keys
      }.compact
    end

    # Stated in words as well as numbers, because "9 of 11" invites the reader to
    # assume the other two failed.
    def coverage_statement
      coverage = verdict.coverage
      {
        "layers_expected" => coverage[:expected],
        "layers_answered" => coverage[:answered],
        "ratio_of_expected" => coverage[:ratio],
        "share_of_all_platform_layers" => coverage[:breadth],
        "not_enabled_for_this_account" => coverage[:not_enabled],
        "not_applicable_to_this_lead" => coverage[:not_applicable],
        "unavailable_at_the_time" => coverage[:unavailable],
        "skipped_for_credits" => coverage[:skipped_for_credits],
        "skipped_after_hard_stop" => coverage[:skipped_after_hard_stop],
        "note" => "Layers listed as not enabled were never checked. They must not be " \
                  "read as having passed."
      }
    end
  end
end
