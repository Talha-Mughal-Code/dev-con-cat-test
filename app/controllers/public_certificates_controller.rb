# Public certificate verification.
#
# A buyer hands a serial to a regulator, a plaintiff's counsel, or the seller
# who invoiced them, and that party must be able to check authenticity without
# an account here.
#
# WHAT IT DOES NOT RETURN: personal data. Proving that a document is authentic
# should not require disclosing its contents to anyone holding a serial number.
# So this shows the integrity result, the verdict, the timestamps, and which
# layers ran - and the lead's name, email and phone only to a signed-in user of
# the owning account.
class PublicCertificatesController < ActionController::Base
  layout "plain"

  def show
    @certificate = TenantScope.across_accounts do
      ConsentCertificate.find_by(serial: params[:serial])
    end

    return render "shared/certificate_not_found", status: :not_found if @certificate.nil?

    @result = @certificate.verify
    @summary = redacted_summary(@certificate)
  end

  # The public key certificates are signed with, so verification does not depend
  # on this endpoint - or on trusting us. Anyone can check a signature offline.
  def public_key
    signer = Certificates::Signer.instance

    render json: {
      key_id: signer.key_id,
      algorithm: signer.algorithm,
      public_key_pem: signer.public_key_pem,
      note: "Verify: signature is Ed25519 over the SHA-256 hex digest of the " \
            "certificate's canonical JSON payload."
    }
  end

  private

  # Enough to prove the document is genuine and to see what was checked, with
  # nothing that identifies the consumer.
  def redacted_summary(certificate)
    payload = certificate.payload

    {
      serial: certificate.serial,
      issued_at: certificate.issued_at,
      issued_to: payload.dig("account", "company_name"),
      verdict: payload.dig("verdict", "value"),
      verdict_reason: payload.dig("verdict", "reasons")&.first&.fetch("message", nil),
      consent_certificate_retained: payload.dig("consent", "trusted_form_cert_url").present?,
      consent_verified: payload.dig("consent", "trusted_form_verified"),
      landing_page: payload.dig("consent", "landing_page_url"),
      lead_captured_at: payload.dig("lead", "captured_at"),
      layers: Array(payload["layers"]).map do |layer|
        { name: layer["name"], state: layer["state"], signal: layer["signal"] }
      end,
      coverage: payload["coverage"],
      digest: certificate.content_digest,
      algorithm: certificate.algorithm,
      key_id: certificate.key_id
    }
  end
end
