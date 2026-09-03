class PixelsController < ApplicationController
  before_action :load_pixel, only: %i[show edit update]

  def index
    authorize! :view_pixels

    with_tenant_scope do
      @pixels = Pixel.order(:created_at).includes(:leads)
      @lead_counts = Lead.group(:pixel_id).count
    end
  end

  def show
    authorize! :view_pixels, @pixel

    with_tenant_scope do
      @snippet = snippet_for(@pixel)
      @recent_leads = Lead.where(pixel: @pixel).recent.limit(10)
      @enabled_modules = current_account.enabled_module_costs
      @sessions_today = CaptureSession.where(pixel: @pixel, started_at: Time.current.all_day).count
    end
  end

  def new
    authorize! :create_pixel

    with_tenant_scope { @pixel = Pixel.new(allowed_origins: []) }
  end

  def create
    authorize! :create_pixel

    with_tenant_scope do
      @pixel = Pixel.new(pixel_params)
      @pixel.account = current_account

      if @pixel.save
        redirect_to pixel_path(@pixel), notice: "Pixel #{@pixel.public_id} created. Copy the snippet below."
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  def edit
    authorize! :edit_pixel, @pixel
  end

  def update
    authorize! :edit_pixel, @pixel

    with_tenant_scope do
      if @pixel.update(pixel_params)
        redirect_to pixel_path(@pixel), notice: "Pixel updated."
      else
        render :edit, status: :unprocessable_entity
      end
    end
  end

  private

  def load_pixel
    with_tenant_scope { @pixel = Pixel.find_by!(public_id: params[:public_id]) }
  end

  # account_id is deliberately absent from the permitted list. A form cannot
  # move a pixel between accounts, and the tenant scope would refuse it anyway.
  def pixel_params
    permitted = params.require(:pixel).permit(:name, :status, :allowed_origins)
    permitted[:allowed_origins] = split_origins(permitted[:allowed_origins])
    permitted
  end

  # The form takes one origin per line, which is how a human thinks about a
  # list of landing pages.
  def split_origins(raw)
    raw.to_s.split(/[\s,]+/).map(&:strip).compact_blank.uniq
  end

  def snippet_for(pixel)
    pixel.snippet(
      endpoint: api_pixel_endpoint_url,
      script_url: pixel_script_url
    )
  end

  def api_pixel_endpoint_url
    "#{request.base_url}/api/pixel"
  end

  def pixel_script_url
    "#{request.base_url}/super-pixel.js"
  end
end
