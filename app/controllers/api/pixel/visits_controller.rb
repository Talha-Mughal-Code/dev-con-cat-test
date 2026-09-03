module Api
  module Pixel
    # POST /api/pixel/visit - the beacon the pixel fires on page load.
    #
    # Returns the capture-session token that /leads will require, which is what
    # ties a later submission to a page load that actually happened on an
    # allowed origin.
    class VisitsController < BaseController
      def create
        session = Capture::VisitRecorder.call(
          pixel: @pixel, params: visit_params, ip: request.remote_ip,
          user_agent: request.user_agent
        )

        render json: {
          session_id: session.public_id,
          token: session_token.issue(purpose: :capture, subject: session.public_id,
                                     ip: request.remote_ip),
          # The pixel advertises the layers this account actually pays for, so
          # the live panel shows the real stack rather than a hardcoded list.
          layers: enabled_layers
        }, status: :accepted
      end

      private

      def visit_params
        params.permit(:session_id, :pixel_id, :page_url, :referrer, :started_at, :campaign)
      end

      def enabled_layers
        TenantScope.for_account(account) do
          costs = account.enabled_module_costs
          DetectionModule.ordered.filter_map do |mod|
            next unless costs.key?(mod.key)

            { key: mod.key, name: mod.name }
          end
        end
      end
    end
  end
end
