module Capture
  # Short-lived, purpose-scoped tokens for the pixel's public endpoints.
  #
  # WHY THEY EXIST. The pixel id is public - it sits in the page source - so on
  # its own it proves nothing: a script could POST leads straight to /leads all
  # day. A capture token means a lead can only be submitted by something that
  # first loaded the page from an allowed origin and got a token back.
  #
  # WHAT A TOKEN BINDS. Its purpose, its subject, and the visitor's IP, plus an
  # issue time. So a token cannot be moved to another session, reused for
  # another job, replayed from another network, or used after it expires.
  #
  # WHY TWO PURPOSES. The activity stream is consumed by EventSource, which
  # cannot set request headers - so its credential has to travel in the URL,
  # where it may end up in access logs and browser history. Rather than put the
  # capture token there, /leads issues a separate STREAM token: five minutes,
  # one lead, read-only. If it leaks, the blast radius is "somebody could watch
  # one lead's verification for five minutes", not "somebody can inject leads
  # into this account".
  #
  # WHY HMAC RATHER THAN A DATABASE ROW. It is verified on the hot path of a form
  # submission and carries no state we do not already have. Signing with the
  # PIXEL's own secret rather than a global key means revoking or rotating a
  # pixel invalidates every token it ever issued - which is what a buyer would
  # expect "revoke this pixel" to mean.
  #
  # WHAT IT IS NOT. It is not evidence the visitor is human, and it is no defence
  # against someone scripting the real page. That is what the detection layers
  # are for. This only ensures a submission belongs to a real session on an
  # authorised page.
  class SessionToken
    PURPOSES = {
      # Long enough for a slow form-filler, short enough that a leaked token is
      # worthless before it could be used at any scale.
      capture: 30.minutes,
      # Only needs to outlive one verification run.
      stream: 5.minutes
    }.freeze

    class Invalid < StandardError; end

    def initialize(pixel)
      @pixel = pixel
    end

    def issue(purpose:, subject:, ip:)
      raise ArgumentError, "unknown purpose #{purpose}" unless PURPOSES.key?(purpose.to_sym)

      issued_at = Time.current.to_i
      "#{purpose}.#{issued_at}.#{sign(payload(purpose, subject, ip, issued_at))}"
    end

    def valid?(token, purpose:, subject:, ip:)
      verify!(token, purpose: purpose, subject: subject, ip: ip)
      true
    rescue Invalid
      false
    end

    def verify!(token, purpose:, subject:, ip:)
      claimed_purpose, issued_at, signature = token.to_s.split(".", 3)
      raise Invalid, "malformed token" if signature.blank? || issued_at.blank?
      raise Invalid, "wrong purpose" unless claimed_purpose == purpose.to_s

      ttl = PURPOSES.fetch(purpose.to_sym) { raise Invalid, "unknown purpose" }
      age = Time.current.to_i - issued_at.to_i
      raise Invalid, "token expired" if age > ttl.to_i
      # A token from the future means a clock problem or a forgery attempt.
      raise Invalid, "token not yet valid" if age < -60

      expected = sign(payload(claimed_purpose, subject, ip, issued_at.to_i))
      # Constant-time, so the comparison cannot be used as an oracle to forge a
      # signature byte by byte.
      unless ActiveSupport::SecurityUtils.secure_compare(signature, expected)
        raise Invalid, "signature mismatch"
      end

      true
    end

    private

    attr_reader :pixel

    def payload(purpose, subject, ip, issued_at)
      [ purpose, pixel.public_id, subject, ip, issued_at ].join("|")
    end

    def sign(body)
      OpenSSL::HMAC.hexdigest("SHA256", pixel.signing_secret, body)
    end
  end
end
