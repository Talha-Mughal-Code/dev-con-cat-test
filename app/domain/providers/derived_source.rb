module Providers
  # Vendor responses for a lead the fixtures do not cover - which is every lead
  # submitted through the live demo page.
  #
  # WHAT THIS IS AND IS NOT. It stands in for the VENDOR APIs, never for the
  # engine. The brief supplies mock data precisely so we do not call real
  # vendors; this is the same idea extended to leads the mock data could not
  # anticipate. The engine cannot tell a derived payload from a fixture one, and
  # no verdict logic lives here - only "what would a vendor plausibly have said
  # about this contact".
  #
  # Two strategies, in order:
  #
  #   1. KNOWN CONTACT. If the phone or email matches a seeded lead, reuse that
  #      lead's vendor responses. This is not a shortcut - it is what a real
  #      vendor does. Blacklist Alliance recognises a litigator by their phone
  #      number, not by our internal lead id. So typing Robert Vance's number
  #      into the demo form gets you caught as a litigator, exactly as it should.
  #
  #   2. HEURISTICS. For a genuinely unknown contact, derive from observable
  #      properties of the submission: disposable email domains, unresolvable
  #      domains, automation in the user agent, implausible dwell time. All
  #      deterministic, so the demo behaves the same way twice.
  class DerivedSource
    DISPOSABLE_DOMAINS = %w[
      mail-tempz.example mailinator.com guerrillamail.com 10minutemail.com
      tempmail.com throwaway.email trashmail.com yopmail.com sharklasers.com
      temp-mail.org dispostable.com getnada.com
    ].freeze

    AUTOMATION_AGENTS = [
      /python-requests/i, /curl\//i, /wget/i, /headlesschrome/i, /phantomjs/i,
      /scrapy/i, /puppeteer/i, /playwright/i, /go-http-client/i, /okhttp/i,
      /java\//i, /libwww/i, /bot|crawler|spider/i
    ].freeze

    # Reserved-for-fiction exchange (555-01xx). Real carriers do not issue them,
    # so a validator would not find them.
    FICTIONAL_PHONE = /\A\+1\d{3}555 ?01\d{2}\z/

    def initialize(lead_context, capture_session: nil, known_contact_finder: nil)
      @context = lead_context
      @capture_session = capture_session
      @known_contact_finder = known_contact_finder || method(:default_known_contact_finder)
    end

    def fetch(provider_key)
      payload = known_contact_payload(provider_key) || heuristic_payload(provider_key)
      # First-party facts always win over anything inherited from a known
      # contact: the IPs and dwell time we recorded are about THIS submission.
      overlay_first_party_facts(provider_key, payload)
    end

    private

    attr_reader :context, :capture_session

    def known_contact = @known_contact ||= @known_contact_finder.call(context)

    def default_known_contact_finder(ctx)
      candidates = []
      candidates << Lead.where(email_normalized: ctx.email_normalized) if ctx.email_normalized.present?
      candidates << Lead.where(phone_normalized: ctx.phone_normalized) if ctx.phone_normalized.present?
      return nil if candidates.empty?

      # Only seeded leads carry fixtures, and never match the lead against
      # itself.
      TenantScope.across_accounts do
        candidates.reduce(:or)
                  .where(origin: "seed")
                  .where.not(public_id: ctx.public_id)
                  .order(:captured_at)
                  .first
      end
    end

    def known_contact_payload(provider_key)
      return nil if known_contact.blank?

      ProviderFixture.lookup(provider_key, known_contact.public_id)
    end

    def heuristic_payload(provider_key)
      case provider_key.to_s
      when "vpn_proxy"          then derive_vpn_proxy
      when "anura"              then derive_anura
      when "trustedform"        then derive_trustedform
      when "blacklist_alliance" then { "status" => "clean", "match_score" => 0, "sources" => [] }
      when "dnc"                then derive_dnc
      when "phone_validation"   then derive_phone
      when "email_validation"   then derive_email
      when "enrichment"         then derive_enrichment
      when "voice"              then { "has_sample" => false, "verdict" => nil }
      else {}
      end
    end

    # --- first-party overlay -------------------------------------------------

    def overlay_first_party_facts(provider_key, payload)
      return payload if payload.blank?

      case provider_key.to_s
      when "vpn_proxy"
        match = capture_session&.ip_consistent?
        payload = payload.merge("site_visit_ip_matches_submit_ip" => match) unless match.nil?
      when "trustedform"
        # A live submission's certificate is about the page it was actually
        # captured on, not the page some other lead used.
        if context.landing_page_url.present?
          payload = payload.merge("page_url" => context.landing_page_url)
        end
      end
      payload
    end

    # --- heuristics ----------------------------------------------------------

    def derive_vpn_proxy
      match = capture_session&.ip_consistent?
      loopback = context.ip_address.to_s.in?(%w[127.0.0.1 ::1 localhost])
      {
        "is_vpn" => false, "is_proxy" => false, "is_tor" => false,
        "is_datacenter" => false,
        "site_visit_ip_matches_submit_ip" => match.nil? ? true : match,
        "risk" => "low",
        "notes" => loopback ? "Local submission (#{context.ip_address}); no reputation data" : nil
      }.compact
    end

    def derive_anura
      rules = []
      rules << "AUTOMATION_TOOL" if automated_agent?
      rules << "FORM_FILL_TOO_FAST" if context.form_dwell_ms.to_i.positive? && context.form_dwell_ms < 1_000

      if rules.any?
        { "result" => "bad", "rule_ids" => rules, "invalid_traffic_type" => "bot",
          "confidence" => 0.97 }
      elsif context.form_dwell_ms.to_i.positive? && context.form_dwell_ms < 3_000
        { "result" => "suspect", "rule_ids" => [ "FORM_FILL_FAST" ],
          "invalid_traffic_type" => nil, "confidence" => 0.58 }
      else
        { "result" => "good", "rule_ids" => [], "invalid_traffic_type" => nil,
          "confidence" => 0.95 }
      end
    end

    # The demo page has no real ActiveProspect integration, so a live submission
    # gets a certificate that matches what the pixel actually captured. Stubbed
    # deliberately and called out in SOLUTION.md - inventing a mismatch would
    # make every demo lead fail the layer the whole product rests on.
    def derive_trustedform
      captured = context.captured_at || Time.current
      {
        "status" => "verified",
        "cert_created_at" => captured.utc.iso8601,
        "matches_phone" => true,
        "matches_email" => true,
        "page_url" => context.landing_page_url,
        "consent_language_present" => context.consent_checkbox != false,
        "expires_at" => (captured + 1.year).utc.iso8601,
        "notes" => "Derived for a live capture; no ActiveProspect integration in this build."
      }
    end

    def derive_dnc
      { "dnc_status" => "callable", "national_dnc" => false, "state_dnc" => false,
        "internal_dnc" => false, "callback_window_open" => true, "last_contact_at" => nil }
    end

    def derive_phone
      phone = context.phone_normalized.to_s
      plausible = phone.match?(/\A\+1\d{10}\z/)
      fictional = phone.gsub(" ", "").match?(FICTIONAL_PHONE)

      if phone.blank? || !plausible
        invalid = { "valid" => false, "line_type" => "unknown", "carrier" => nil }
        { "providers" => { "twilio_lookup" => invalid, "numverify" => invalid,
                           "telesign" => invalid } }
      elsif fictional
        # Reserved range: two providers reject it, one guesses VoIP. A genuine
        # split, which is exactly what the phone consensus layer exists to catch.
        { "providers" => {
          "twilio_lookup" => { "valid" => false, "line_type" => "unknown", "carrier" => nil },
          "numverify" => { "valid" => false, "line_type" => "unknown", "carrier" => nil },
          "telesign" => { "valid" => true, "line_type" => "voip", "carrier" => "Bandwidth" }
        } }
      else
        valid = { "valid" => true, "line_type" => "mobile", "carrier" => "Verizon" }
        { "providers" => { "twilio_lookup" => valid, "numverify" => valid,
                           "telesign" => valid } }
      end
    end

    def derive_email
      email = context.email_normalized.to_s
      domain = email.split("@").last.to_s
      disposable = DISPOSABLE_DOMAINS.include?(domain)
      # Non-ASCII in a domain is the homoglyph trick the fixtures use for
      # L-1008: it looks like a real domain and does not resolve.
      homoglyph = domain.present? && !domain.ascii_only?
      unresolvable = domain.blank? || homoglyph || domain.end_with?(".invalid") ||
                     !domain.include?(".")

      if disposable
        { "providers" => {
          "zerobounce" => { "deliverable" => false, "disposable" => true, "fraud_score" => 92 },
          "neverbounce" => { "deliverable" => false, "disposable" => true, "fraud_score" => 87 }
        } }
      elsif unresolvable
        { "providers" => {
          "zerobounce" => { "deliverable" => false, "disposable" => false, "fraud_score" => 70 },
          "neverbounce" => { "deliverable" => false, "disposable" => false, "fraud_score" => 65 }
        } }
      else
        { "providers" => {
          "zerobounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 6 },
          "neverbounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 8 }
        } }
      end
    end

    def derive_enrichment
      named = context.email_normalized.present? && context.phone_normalized.present?
      return { "audiencelabs" => { "matched" => false, "address" => nil, "age_band" => nil,
                                   "household_income" => nil, "match_to_lead" => false },
               "bytemine" => { "matched" => false, "address" => nil, "age_band" => nil,
                               "match_to_lead" => false } } unless named

      { "audiencelabs" => { "matched" => true, "address" => nil, "age_band" => nil,
                            "household_income" => nil, "match_to_lead" => true,
                            "notes" => "Derived for a live capture; no enrichment vendor in this build." },
        "bytemine" => { "matched" => true, "address" => nil, "age_band" => nil,
                        "match_to_lead" => true } }
    end

    def automated_agent?
      ua = context.user_agent.to_s
      return false if ua.blank?

      AUTOMATION_AGENTS.any? { |pattern| ua.match?(pattern) }
    end
  end
end
