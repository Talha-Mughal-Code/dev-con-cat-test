module Api
  module Pixel
    # POST /api/pixel/leads - the lead itself.
    class LeadsController < BaseController
      before_action :require_capture_token

      def create
        lead = Capture::LeadIngestor.call(
          pixel: @pixel, params: lead_params, ip: request.remote_ip,
          user_agent: request.user_agent
        )

        # Returns the lead id and the stream URL so the pixel can subscribe
        # immediately. Nothing about the verdict: verification has only just been
        # enqueued, and pretending otherwise would mean blocking this response on
        # eleven vendor calls.
        # A separate, narrower credential for the stream: EventSource cannot set
        # headers, so this one has to travel in a URL. Five minutes, one lead,
        # read-only.
        stream_token = session_token.issue(purpose: :stream, subject: lead.public_id,
                                           ip: request.remote_ip)

        render json: {
          lead_id: lead.public_id,
          # The pixel id travels with the stream URL because it is what
          # identifies the origin allowlist to check and the secret the stream
          # token was signed with. Without it the stream endpoint has no way to
          # know which pixel is asking - and would have to look the lead up
          # across every account to find out, which is exactly the cross-tenant
          # read the design forbids.
          activity_url: api_pixel_lead_activity_path(lead_public_id: lead.public_id,
                                                     pixel_id: @pixel.public_id),
          stream_token: stream_token
        }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      private

      def lead_params
        params.permit(
          :session_id, :pixel_id, :submitted_at, :form_dwell_ms, :page_url, :campaign,
          fields: {}, interactions: [ :name, :action, :at ]
        )
      end

      # Without this, the public pixel id would be enough to inject leads into a
      # buyer's account from anywhere.
      def require_capture_token
        return if session_token.valid?(params[:token], purpose: :capture,
                                       subject: claimed_session_public_id,
                                       ip: request.remote_ip)

        render_error("a valid capture session token is required - call /visit first", :unauthorized)
      end

      def claimed_session_public_id
        supplied = params[:session_id].to_s.gsub(/[^a-zA-Z0-9_\-]/, "")[0, 64]
        supplied.start_with?("sess_") ? supplied : "sess_#{Digest::SHA256.hexdigest(supplied)[0, 24]}"
      end
    end
  end
end
