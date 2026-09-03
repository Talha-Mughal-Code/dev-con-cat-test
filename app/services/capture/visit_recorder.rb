module Capture
  # Handles the /visit beacon the pixel fires on page load.
  #
  # This runs before the visitor has typed anything, and that is the point: it
  # records the IP they are BROWSING from, so the VPN layer can later compare it
  # against the IP they SUBMIT from. Without a beacon at page load there is only
  # one IP to look at, and the whole "browsed on a real IP, submitted through a
  # VPN" class of fraud becomes invisible.
  #
  # THE BEACON MUST BE IDEMPOTENT. A pixel can fire it more than once for the
  # same session, and not because anything is wrong: fetch(keepalive) retries,
  # a browser prefetches, a visitor double-clicks a reload, a single-page app
  # re-mounts the tag. Two of those arriving concurrently used to race
  # find_or_initialize_by against save! and return a 500.
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
        session = upsert_session
        # Only on first sight, or a re-fired beacon would put a duplicate row in
        # the visitor's activity panel.
        Activity::Recorder.session_started(session) if session.previously_new_record?
        session
      end
    end

    private

    attr_reader :pixel, :params, :ip, :user_agent

    def upsert_session
      attempts = 0

      begin
        # Also generous: without a capture session there is no visit IP to
        # compare against the submit IP later, so the VPN layer loses its most
        # useful signal for this lead.
        Database::Retry.on_contention(attempts: 8) do
          session = CaptureSession.find_or_initialize_by(public_id: public_id)
          session.assign_attributes(attributes_for(session))
          session.save!
          session
        end
      rescue ActiveRecord::RecordNotUnique
        # Another beacon for this session won the insert between our lookup and
        # our write. The row it created is just as good as the one we wanted, so
        # go round once and update that instead.
        attempts += 1
        raise if attempts > 1

        retry
      end
    end

    def attributes_for(session)
      attributes = {
        account: pixel.account, pixel: pixel,
        page_url: params[:page_url], referrer: params[:referrer],
        # From the request header, not the body: the body is client-supplied and
        # the header is at least what actually reached us.
        user_agent: user_agent,
        visit_ip: ip
      }

      # started_at is set ONCE, on first sight. Two reasons. A repeat beacon
      # would otherwise reset the dwell clock, so a visitor who filled the form
      # slowly and honestly would be re-timed to zero and flagged as an instant
      # fill. And it hands the client a lever on a fraud signal: re-fire the
      # beacon just before submitting and the measured dwell becomes whatever
      # you like.
      attributes[:started_at] = Time.current if session.new_record?
      attributes
    end

    # The client proposes a session id so it can correlate its own events, but it
    # is namespaced, length-capped and hashed here rather than trusted verbatim.
    def public_id
      supplied = params[:session_id].to_s.gsub(/[^a-zA-Z0-9_\-]/, "")[0, 64]
      return "sess_#{SecureRandom.hex(12)}" if supplied.blank?

      "sess_#{Digest::SHA256.hexdigest(supplied)[0, 24]}"
    end
  end
end
