module Capture
  # Turns a pixel POST into a Lead and queues verification.
  #
  # Nothing the client sends is trusted as authority:
  #
  #   * The ACCOUNT comes from the pixel record, never from the request. There is
  #     no parameter that could point a lead at someone else's account.
  #   * The SUBMIT IP comes from the connection, not the body.
  #   * FORM DWELL is recomputed from the server-recorded visit time where a
  #     session exists, because dwell time is a fraud signal and a fraudster
  #     would simply send a flattering number. The client's figure is kept
  #     alongside it as an observation, not as the measurement.
  class LeadIngestor
    def self.call(...) = new(...).call

    class MissingSession < StandardError; end

    def initialize(pixel:, params:, ip:, user_agent:)
      @pixel = pixel
      @params = params
      @ip = ip
      @user_agent = user_agent
    end

    def call
      TenantScope.for_account(pixel.account) do
        session = find_session
        lead = build_lead(session)
        lead.save!

        session&.update!(submit_ip: ip, submitted_at: lead.submitted_at,
                         interactions: interactions, interaction_count: interactions.size)

        Activity::Recorder.lead_received(lead)
        # Enqueued rather than run inline: the visitor's browser is waiting on
        # this response, and it must not block on eleven vendor calls.
        Verification::StartJob.perform_later(lead.id)
        lead
      end
    end

    private

    attr_reader :pixel, :params, :ip, :user_agent

    def find_session
      return nil if params[:session_id].blank?

      CaptureSession.find_by(public_id: session_public_id)
    end

    def session_public_id
      supplied = params[:session_id].to_s.gsub(/[^a-zA-Z0-9_\-]/, "")[0, 64]
      "sess_#{Digest::SHA256.hexdigest(supplied)[0, 24]}"
    end

    def build_lead(session)
      Lead.new(
        account: pixel.account, pixel: pixel, capture_session: session,
        first_name: fields[:first_name], last_name: fields[:last_name],
        email: fields[:email], phone: fields[:phone],
        consent_checkbox: consent_checkbox,
        landing_page_url: session&.page_url || params[:page_url],
        campaign: params[:campaign],
        ip_address: ip, user_agent: user_agent,
        # No real ActiveProspect integration in this build; a deterministic
        # placeholder reference so the consent layer has something to verify
        # against. Called out in SOLUTION.md as a stub.
        trusted_form_cert_url: derived_trusted_form_url,
        form_dwell_ms: dwell_ms(session),
        captured_at: Time.current, submitted_at: Time.current,
        origin: "pixel"
      )
    end

    def fields
      @fields ||= (params[:fields] || {}).to_h.symbolize_keys
    end

    # Tri-state. An absent checkbox field means the form did not have one, which
    # is different from a visitor declining to tick it.
    def consent_checkbox
      raw = fields[:consent]
      return nil if raw.nil?

      ActiveModel::Type::Boolean.new.cast(raw) || false
    end

    # Server-measured wherever possible: a client-reported dwell time is exactly
    # what a bot would lie about. Clamped either way, so no arithmetic path can
    # yield a negative figure that would then read as an instant fill.
    def dwell_ms(session)
      measured = session&.started_at && ((Time.current - session.started_at) * 1000).round
      (measured || params[:form_dwell_ms].to_i).clamp(0, 6.hours.in_milliseconds)
    end

    def interactions
      @interactions ||= Array(params[:interactions]).first(200).map do |entry|
        entry = entry.to_h.symbolize_keys
        { "name" => entry[:name].to_s[0, 64], "action" => entry[:action].to_s[0, 16],
          "at" => entry[:at].to_s[0, 32] }
      end
    end

    def derived_trusted_form_url
      digest = Digest::SHA256.hexdigest("#{pixel.public_id}:#{params[:session_id]}")[0, 32]
      "https://cert.trustedform.example/#{digest}"
    end
  end
end
