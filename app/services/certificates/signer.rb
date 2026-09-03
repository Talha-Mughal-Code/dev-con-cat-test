module Certificates
  # Signs certificate digests.
  #
  # Ed25519 rather than an HMAC, deliberately. With a shared secret we would be
  # the only party able to verify, so a buyer defending a lead would be asking a
  # regulator to take our word for it. With a public key they - or their
  # counsel, or the lead's seller - can verify independently, and we cannot
  # later deny having issued a certificate we signed.
  #
  # KEY MANAGEMENT is stubbed for this exercise and the stub is the honest kind:
  # a key generated on first use in development and written to a gitignored PEM.
  # Production supplies CERTIFICATE_SIGNING_KEY. What a real deployment needs and
  # this does not have is rotation with overlapping validity, which is why
  # key_id is recorded on every certificate - verification looks up the key that
  # signed it rather than assuming the current one.
  class Signer
    ALGORITHM = "ed25519"
    KEY_PATH = Rails.root.join("config/certificate_signing_key.pem")

    class MissingKey < StandardError; end

    class << self
      def instance = @instance ||= new

      # Allows a test to sign with a throwaway key without touching the
      # filesystem or the process-wide instance.
      def with_key(pem)
        previous = @instance
        @instance = new(pem: pem)
        yield @instance
      ensure
        @instance = previous
      end

      def reset! = @instance = nil
    end

    def initialize(pem: nil)
      @pem = pem
    end

    def sign(digest)
      Base64.strict_encode64(private_key.sign(nil, digest))
    end

    def verify(digest, signature, key_id: nil)
      return false if signature.blank?

      key = key_id.present? && key_id != self.key_id ? nil : public_key
      # An unknown key_id is a verification failure rather than an exception: a
      # certificate signed by a key we have retired is exactly the case a caller
      # needs told about, not crashed over.
      return false if key.nil?

      key.verify(nil, Base64.decode64(signature), digest)
    rescue OpenSSL::PKey::PKeyError, ArgumentError
      false
    end

    def algorithm = ALGORITHM

    # Derived from the public key rather than assigned, so it is stable, and so
    # two deployments holding the same key agree on its name.
    def key_id
      @key_id ||= "ed25519:#{Digest::SHA256.hexdigest(public_key_der)[0, 16]}"
    end

    def public_key_pem = public_key.public_to_pem

    private

    def public_key = @public_key ||= OpenSSL::PKey.read(private_key.public_to_pem)

    def public_key_der = public_key.public_to_der

    def private_key
      @private_key ||= OpenSSL::PKey.read(key_material)
    end

    def key_material
      return @pem if @pem.present?
      return ENV["CERTIFICATE_SIGNING_KEY"] if ENV["CERTIFICATE_SIGNING_KEY"].present?
      return KEY_PATH.read if KEY_PATH.exist?

      unless Rails.env.local?
        raise MissingKey, "CERTIFICATE_SIGNING_KEY must be set outside development and test"
      end

      generate_development_key!
    end

    # Generated once and kept, so certificates issued yesterday still verify
    # today. Gitignored, because a signing key in version control is not a
    # signing key.
    def generate_development_key!
      pem = OpenSSL::PKey.generate_key("ED25519").private_to_pem
      KEY_PATH.dirname.mkpath
      KEY_PATH.write(pem)
      KEY_PATH.chmod(0o600)
      Rails.logger.info("generated a development certificate signing key at #{KEY_PATH}")
      pem
    end
  end
end
