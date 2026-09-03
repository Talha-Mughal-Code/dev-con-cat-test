module Api
  module Pixel
    # GET /api/pixel/leads/:lead_public_id/activity - the live event stream.
    #
    # AUTHORIZATION. This is a public endpoint on a public page, so there is no
    # logged-in user to check. Access is granted by the capture token: it proves
    # the caller opened the session that produced this lead. Without that check,
    # anyone who guessed a lead id could watch another buyer's verification
    # results stream past, including the consumer's own details.
    class ActivityController < BaseController
      include ActionController::Live

      before_action :load_lead
      before_action :require_stream_authorization

      def show
        # A polling fallback for anything without EventSource. Same cursor
        # semantics as the stream, so the two paths cannot disagree about what
        # has already been delivered.
        return render_json_batch if params[:format] == "json"

        response.headers["Content-Type"] = "text/event-stream"
        response.headers["Cache-Control"] = "no-cache"
        # Tells nginx and friends not to buffer, which would otherwise hold
        # events until the response ended and defeat the entire point.
        response.headers["X-Accel-Buffering"] = "no"
        response.headers["Last-Modified"] = Time.current.httpdate

        Sse::Streamer.new(
          stream: response.stream,
          lead_id: @lead.id,
          account: account,
          cursor: request.headers["Last-Event-ID"] || params[:cursor]
        ).call
      ensure
        response.stream.close
      end

      private

      def render_json_batch
        events = TenantScope.for_account(account) do
          ActivityEvent.where(lead_id: @lead.id)
                       .after_cursor(params[:cursor]).chronological.limit(50).to_a
        end

        render json: events.map(&:to_stream_event)
      end

      def load_lead
        @lead = TenantScope.for_account(account) do
          Lead.find_by(public_id: params[:lead_public_id])
        end

        # A lead belonging to another account is indistinguishable from one that
        # does not exist, because the tenant scope means we never even looked
        # outside this pixel's account.
        render_error("unknown lead", :not_found) if @lead.nil?
      end

      def require_stream_authorization
        return if session_token.valid?(params[:token], purpose: :stream,
                                       subject: @lead.public_id, ip: request.remote_ip)

        render_error("a valid stream token is required - it is returned by POST /leads",
                     :unauthorized)
      end
    end
  end
end
