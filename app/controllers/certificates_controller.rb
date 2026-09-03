class CertificatesController < ApplicationController
  before_action :load_certificate

  def show
    authorize! :view_certificate, @certificate

    @result = @certificate.verify
    @layers = @certificate.payload.fetch("layers", [])
  end

  # Re-runs verification on demand rather than trusting a stored flag, because a
  # cached "valid" is exactly what an attacker who edited the row would want.
  def verify
    authorize! :verify_certificate, @certificate

    @result = @certificate.verify
    respond_to do |format|
      format.html { render :show }
      format.json do
        render json: {
          serial: @certificate.serial, status: @result.status,
          digest_ok: @result.digest_ok, signature_ok: @result.signature_ok,
          chain_ok: @result.chain_ok, details: @result.details
        }
      end
    end
  end

  private

  def load_certificate
    with_tenant_scope { @certificate = ConsentCertificate.find_by!(serial: params[:serial]) }
  end
end
