# The assignment's landing page, served by this app.
#
# Served by Rails rather than opened as a file so the pixel gets a real
# data-endpoint and a real pixel id belonging to a real account - which is the
# whole "prove it works end to end" deliverable. Opening
# examples/landing-page.html from disk still works, but it runs the simulation;
# this route runs the backend.
class DemoController < ApplicationController
  allow_unauthenticated

  layout false

  def show
    @pixel = TenantScope.across_accounts do
      if params[:pixel_public_id].present?
        Pixel.active.find_by(public_id: params[:pixel_public_id])
      else
        Pixel.active.order(:created_at).first
      end
    end

    return render "shared/no_pixel", layout: "plain", status: :not_found if @pixel.nil?

    @account = @pixel.account
    @endpoint = "#{request.base_url}/api/pixel"
    @layers = TenantScope.for_account(@account) do
      costs = @account.enabled_module_costs
      DetectionModule.ordered.filter_map do |mod|
        { key: mod.key, name: mod.name, enabled: costs.key?(mod.key) }
      end
    end
  end
end
