module Capture
  # Handles the /visit beacon the pixel fires on page load.
  #
  # This exists before the visitor has typed anything, and that is the point: it
  # records the IP they are BROWSING from, so the VPN layer can later compare it
  # against the IP they SUBMIT from. Without a beacon at page load there is only
  # one IP to look at, and the whole "browsed on a real IP, submitted through a
  # VPN" class of fraud becomes invisible.
  class VisitRecorder
    def self.call(...) = new(...).call

    def initialize(pixel:, params:, ip:, user_agent:)
      @pixel = pixel
      @params = params
      @ip = ip
      @user_agent = user_agent
    end

    def call
      TenantScope.for_account(pixel.account) do
        session = CaptureSession.find_or_initialize_by(public_id: public_id)
        session.assign_attributes(
          account: pixel.account, pixel: pixel,
          page_url: params[:page_url], referrer: params[:referrer],
          # The user agent is taken from the request header, not the body: the
          # body is client-supplied and the header is at least what actually
          # reached us.
          user_agent: user_agent,
          visit_ip: ip,
          # SERVER time, not the client's. The client sends a started_at, and
          # trusting it would hand a fraudster control of the dwell-time signal:
          # backdate it and the form looks patiently filled, post-date it and
          # the arithmetic goes negative. Its claim is kept in the interaction
          # log as an observation; this is the measurement.
          started_at: Time.current
        )
        session.save!
        Activity::Recorder.session_started(session)
        session
      end
    end

    private

    attr_reader :pixel, :params, :ip, :user_agent

    # The client proposes a session id so it can correlate its own events, but
    # it is namespaced and length-capped here rather than trusted verbatim.
    def public_id
      supplied = params[:session_id].to_s.gsub(/[^a-zA-Z0-9_\-]/, "")[0, 64]
      supplied.presence ? "sess_#{Digest::SHA256.hexdigest(supplied)[0, 24]}" : "sess_#{SecureRandom.hex(12)}"
    end
  end
end
