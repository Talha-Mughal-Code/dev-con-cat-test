module Api
  module Pixel
    # The pixel's public API, called cross-origin from a buyer's landing page.
    #
    # SECURITY MODEL - the three questions docs/pixel-spec.md asks:
    #
    # "How do you stop someone POSTing leads to another account's pixel?"
    #   The pixel id is PUBLIC - it sits in the page source - so it cannot be a
    #   credential, and no request may nominate its own account. The account is
    #   derived server-side from the pixel record, and the pixel carries an
    #   ORIGIN ALLOWLIST set by its owner. A POST whose Origin is not on that
    #   list is refused. An empty allowlist accepts nothing rather than
    #   everything.
    #
    # "What stops the endpoint being abused or replayed?"
    #   /visit issues a short-lived token, HMAC-signed with the pixel's own
    #   secret and bound to the session id, the pixel and the visitor's IP.
    #   /leads will not accept a lead without it. So a lead cannot be
    #   manufactured without first having loaded the page from an allowed origin,
    #   the token expires, and rotating or revoking the pixel invalidates every
    #   token already issued.
    #
    # "What lives client-side versus server-side?"
    #   Client-side: the pixel id, the endpoint, field telemetry, timings. All
    #   of it is visible to the visitor and none of it is trusted. Server-side:
    #   the account mapping, the origin allowlist, the signing secret, the visit
    #   IP, every verdict, and all credit accounting. The client is treated as a
    #   reporter of observations, never as an authority - which is why, for
    #   instance, form_dwell_ms is recomputed from the server-recorded visit time
    #   rather than taken from the browser.
    class BaseController < ActionController::Base
      # No session, no CSRF token: these are cross-origin calls from pages we do
      # not render. Origin allowlisting plus the signed session token do the work
      # a CSRF token would.
      skip_forgery_protection

      before_action :set_cors_headers
      before_action :load_pixel, except: :preflight

      rescue_from ActionController::ParameterMissing do |error|
        render json: { error: error.message }, status: :bad_request
      end

      def preflight
        head :no_content
      end

      private

      def load_pixel
        public_id = params[:pixel_id].presence || params.dig(:lead, :pixel_id)
        @pixel = ::Pixel.unscoped.active.find_by(public_id: public_id)

        return render_error("unknown or inactive pixel", :not_found) if @pixel.nil?
        return if origin_allowed?

        # Refused rather than silently accepted, and logged with the origin, so
        # a buyer who has forgotten to allowlist their new landing page gets a
        # diagnosable answer instead of leads vanishing.
        Rails.logger.warn("pixel #{@pixel.public_id} refused origin #{request_origin.inspect}")
        render_error("origin #{request_origin} is not allowed for this pixel", :forbidden)
      end

      def account = @pixel.account

      def request_origin
        request.headers["Origin"].presence ||
          (request.referer.present? ? URI.join(request.referer, "/").to_s.chomp("/") : nil)
      end

      def origin_allowed?
        # Same-origin requests (the bundled demo page, served by this app) send
        # no Origin header on a same-site POST in some browsers; treat a request
        # from our own host as allowed.
        return true if request_origin.blank? && request.local?

        @pixel.origin_allowed?(request_origin) || own_origin?
      end

      def own_origin?
        return false if request_origin.blank?

        URI.parse(request_origin).host == request.host
      rescue URI::InvalidURIError
        false
      end

      def set_cors_headers
        origin = request.headers["Origin"]
        return if origin.blank?

        # Reflected only for origins a pixel actually authorises, resolved
        # against every active pixel for a preflight (which carries no body to
        # identify one).
        return unless origin_authorised_by_any_pixel?(origin)

        response.headers["Access-Control-Allow-Origin"] = origin
        response.headers["Access-Control-Allow-Methods"] = "POST, GET, OPTIONS"
        response.headers["Access-Control-Allow-Headers"] = "Content-Type, Last-Event-ID"
        response.headers["Access-Control-Max-Age"] = "600"
        response.headers["Vary"] = "Origin"
      end

      def origin_authorised_by_any_pixel?(origin)
        return true if URI.parse(origin).host == request.host

        ::Pixel.unscoped.active.any? { |pixel| pixel.origin_allowed?(origin) }
      rescue URI::InvalidURIError
        false
      end

      def render_error(message, status)
        render json: { error: message }, status: status
      end

      def session_token
        @session_token ||= Capture::SessionToken.new(@pixel)
      end
    end
  end
end
