module Certificates
  # Verifies an issued certificate. Three independent checks, reported
  # separately because they fail for different reasons and mean different things.
  #
  #   digest    - does the stored payload still hash to the stored digest?
  #               Catches an edited body.
  #   signature - was that digest signed by a key we recognise?
  #               Catches a forged or re-digested body.
  #   chain     - does prev_digest still match the account's preceding
  #               certificate? Catches deletion and reordering, which a
  #               signature alone cannot - and which is the attack the platform
  #               operator would be uniquely placed to attempt.
  class Verifier
    Result = Struct.new(:valid, :digest_ok, :signature_ok, :chain_ok, :revoked, :details,
                        keyword_init: true) do
      def valid? = !!valid
      def revoked? = !!revoked

      def status
        return "revoked" if revoked?

        valid? ? "valid" : "tampered"
      end
    end

    def initialize(certificate)
      @certificate = certificate
    end

    def verify
      digest_ok = recomputed_digest == certificate.content_digest
      signature_ok = Signer.instance.verify(certificate.content_digest, certificate.signature,
                                            key_id: certificate.key_id)
      chain_ok, chain_detail = verify_chain

      Result.new(
        valid: digest_ok && signature_ok && chain_ok,
        digest_ok: digest_ok, signature_ok: signature_ok, chain_ok: chain_ok,
        revoked: certificate.revoked?,
        details: {
          algorithm: certificate.algorithm,
          key_id: certificate.key_id,
          recomputed_digest: recomputed_digest,
          stored_digest: certificate.content_digest,
          chain_index: certificate.chain_index,
          chain: chain_detail,
          issued_at: certificate.issued_at,
          revocation_reason: certificate.revocation_reason
        }
      )
    end

    private

    attr_reader :certificate

    def recomputed_digest
      @recomputed_digest ||= Canonical.digest(certificate.payload)
    end

    def verify_chain
      if certificate.chain_index.zero?
        return [ certificate.prev_digest.nil?,
                 certificate.prev_digest.nil? ? "first certificate for this account" : "genesis certificate carries a prev_digest" ]
      end

      previous = TenantScope.for_account(certificate.account) do
        ConsentCertificate.find_by(account: certificate.account,
                                   chain_index: certificate.chain_index - 1)
      end

      return [ false, "certificate #{certificate.chain_index - 1} is missing from the chain" ] if previous.nil?

      if previous.content_digest == certificate.prev_digest
        [ true, "links to #{previous.serial}" ]
      else
        [ false, "prev_digest does not match #{previous.serial}" ]
      end
    end
  end
end
