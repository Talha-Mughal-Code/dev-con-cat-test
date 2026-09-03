module Engine
  # A plain snapshot of the lead, built once at the edge of the engine.
  #
  # Evaluators receive this rather than an ActiveRecord object so that nothing
  # inside app/engine can lazily load an association, issue a query, or mutate a
  # row. The engine stays a pure function of (payload, context), which is what
  # makes it cheap to unit test against every edge case without touching a
  # database.
  LeadContext = Struct.new(
    :public_id, :email, :phone, :email_normalized, :phone_normalized,
    :landing_page_url, :captured_at, :form_dwell_ms, :consent_checkbox,
    :trusted_form_cert_url, :ip_address, :user_agent,
    keyword_init: true
  ) do
    def self.from(lead)
      new(
        public_id: lead.public_id,
        email: lead.email,
        phone: lead.phone,
        email_normalized: lead.email_normalized,
        phone_normalized: lead.phone_normalized,
        landing_page_url: lead.landing_page_url,
        captured_at: lead.captured_at,
        form_dwell_ms: lead.form_dwell_ms,
        consent_checkbox: lead.consent_checkbox,
        trusted_form_cert_url: lead.trusted_form_cert_url,
        ip_address: lead.ip_address,
        user_agent: lead.user_agent
      )
    end

    # Tri-state, and the distinction matters: nil means the checkbox was never
    # captured (the seeded leads predate the pixel), false means it was captured
    # and left unchecked.
    def consent_captured? = !consent_checkbox.nil?
  end
end
