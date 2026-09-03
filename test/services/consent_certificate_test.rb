require "test_helper"

# Consent certificates: what they contain, and whether tampering can be
# detected.
class ConsentCertificateTest < ActiveSupport::TestCase
  # Built on first use rather than in setup, so the tests that need their own
  # account are not fighting a scenario they did not ask for. Named with a
  # prefix because a method called `run` on a test case shadows Minitest's own.
  def scenario
    @scenario ||= begin
      account, lead = build_scenario("L-1001")
      run = verify!(lead)
      { account: account, lead: lead, run: run,
        certificate: TenantScope.for_account(account) { run.consent_certificate } }
    end
  end

  def cert_account = scenario[:account]
  def cert_lead    = scenario[:lead]
  def cert_run     = scenario[:run]
  def cert         = scenario[:certificate]

  # --- integrity ------------------------------------------------------------

  test "a freshly issued certificate verifies on all three checks" do
    result = cert.verify

    assert result.valid?
    assert result.digest_ok
    assert result.signature_ok
    assert result.chain_ok
    assert_equal "valid", result.status
    assert_equal "ed25519", cert.algorithm
  end

  test "editing the payload is detected even though the signature is untouched" do
    # The digest is over the payload, so an edited body no longer hashes to the
    # value that was signed.
    tampered = cert.payload.deep_dup
    tampered["verdict"]["value"] = "reject"
    tampered["lead"]["phone"] = "+15550000000"

    forged = cert.dup
    forged.payload = tampered
    result = Certificates::Verifier.new(forged).verify

    assert_not result.valid?
    assert_not result.digest_ok
    assert_equal "tampered", result.status
  end

  test "re-digesting an edited payload does not help without the signing key" do
    # The obvious next move for a forger: edit the body AND recompute the
    # digest. The signature is over the digest, so that fails instead.
    tampered = cert.payload.deep_dup
    tampered["verdict"]["value"] = "reject"

    forged = cert.dup
    forged.payload = tampered
    forged.content_digest = Certificates::Canonical.digest(tampered)
    result = Certificates::Verifier.new(forged).verify

    assert result.digest_ok, "the digest now matches the edited body"
    assert_not result.signature_ok, "but that digest was never signed"
    assert_not result.valid?
  end

  test "a certificate signed by an unknown key does not verify" do
    other_key = OpenSSL::PKey.generate_key("ED25519").private_to_pem
    forged = cert.dup

    Certificates::Signer.with_key(other_key) do |signer|
      forged.signature = signer.sign(cert.content_digest)
      forged.key_id = signer.key_id
    end

    assert_not Certificates::Verifier.new(forged).verify.signature_ok
  end

  test "the hash chain detects a deleted certificate, which a signature cannot" do
    # The attack a platform operator would be uniquely placed to attempt:
    # quietly drop an inconvenient certificate. Every remaining one still has a
    # perfect signature, so only the chain reveals it.
    second_lead = build_lead(account: cert_account, pixel: cert_lead.pixel, form_dwell_ms: 45_000)
    second_run = verify!(second_lead)

    TenantScope.for_account(cert_account) do
      second = second_run.consent_certificate
      assert_equal 1, second.chain_index
      assert_equal cert.content_digest, second.prev_digest
      assert second.verify.valid?

      ActiveRecord::Base.connection.execute(
        "DELETE FROM consent_certificates WHERE id = #{cert.id}"
      )

      result = second.reload.verify
      assert result.signature_ok, "the surviving certificate is still properly signed"
      assert_not result.chain_ok, "but its link into the chain is now broken"
      assert_not result.valid?
      assert_match(/missing from the chain/, result.details[:chain])
    end
  end

  test "certificates are immutable once issued, enforced by the database" do
    assert cert.readonly?
    assert_raises ActiveRecord::ReadOnlyRecord do
      cert.update!(payload: {})
    end

    assert_raises ActiveRecord::StatementInvalid do
      ActiveRecord::Base.connection.execute(
        "UPDATE consent_certificates SET content_digest = 'x' WHERE id = #{cert.id}"
      )
    end
  end

  test "revocation is additive and leaves the signed body verifiable" do
    # A revoked certificate is still evidence of what was checked and when. It
    # must be annotated, not rewritten.
    cert.revoke!(reason: "lead disputed by the consumer")

    assert cert.reload.revoked?
    assert_equal "lead disputed by the consumer", cert.revocation_reason
    result = cert.verify
    assert result.digest_ok
    assert result.signature_ok
    assert_equal "revoked", result.status
  end

  # --- canonicalisation -----------------------------------------------------

  test "the digest depends on the data, not on hash ordering" do
    # Without canonicalisation, adding a field to the payload builder - or a
    # Ruby version changing hash iteration - would invalidate every certificate
    # ever issued.
    a = { "b" => 1, "a" => { "d" => 2, "c" => [ 3, 4 ] } }
    b = { "a" => { "c" => [ 3, 4 ], "d" => 2 }, "b" => 1 }

    assert_equal Certificates::Canonical.digest(a), Certificates::Canonical.digest(b)
  end

  test "canonicalisation preserves false rather than collapsing it to nil" do
    # "the consent checkbox was ticked: false" becoming "not recorded" is exactly
    # the silent corruption a signed document must not have.
    canonical = Certificates::Canonical.normalize({ "ticked" => false, "other" => nil })

    assert_equal false, canonical["ticked"]
    assert_nil canonical["other"]
  end

  test "array order is significant and preserved" do
    a = Certificates::Canonical.digest({ "layers" => %w[anura dnc] })
    b = Certificates::Canonical.digest({ "layers" => %w[dnc anura] })

    assert_not_equal a, b
  end

  # --- contents -------------------------------------------------------------

  test "the certificate carries the evidence needed to defend the lead" do
    payload = cert.payload

    assert_equal cert_lead.public_id, payload.dig("lead", "public_id")
    assert_equal cert_lead.phone, payload.dig("lead", "phone")
    assert_equal cert_account.public_id, payload.dig("account", "public_id")
    assert_equal cert_lead.pixel.public_id, payload.dig("pixel", "public_id")

    # The retained TrustedForm reference, and our verification of it.
    assert_equal cert_lead.trusted_form_cert_url, payload.dig("consent", "trusted_form_cert_url")
    assert payload.dig("consent", "trusted_form_verified")
    assert payload.dig("consent", "trusted_form_evidence").present?

    # First-party capture evidence - often the most persuasive part of a TCPA
    # defence, and the part no vendor can supply.
    assert_equal cert_lead.form_dwell_ms, payload.dig("capture_evidence", "form_dwell_ms")
    assert_equal cert_lead.user_agent, payload.dig("capture_evidence", "user_agent")

    # The verdict, its reasons, and the policy version that produced it, so the
    # document is reproducible.
    assert_equal "accept", payload.dig("verdict", "value")
    assert payload.dig("verdict", "reasons").any?
    assert_equal cert_run.consensus_policy.version, payload.dig("policy", "version")
    assert payload.dig("policy", "thresholds").present?

    # What the buyer was charged, itemised.
    assert_equal cert_run.credits_charged, payload.dig("billing", "credits_charged")
  end

  test "the certificate lists every layer including the silent ones, with reasons" do
    layers = cert.payload.fetch("layers")

    assert_equal Engine::Registry::MODULE_KEYS.size, layers.size

    voice = layers.find { |l| l["module"] == "voice" }
    assert_equal "not_enabled", voice.fetch("state")
    assert_nil voice["signal"], "a layer nobody paid for must not appear to have passed"
    assert_match(/not enabled/i, voice.fetch("summary"))

    anura = layers.find { |l| l["module"] == "anura" }
    assert_equal "completed", anura.fetch("state")
    assert_equal "pass", anura.fetch("signal")
    assert anura.fetch("evidence").present?, "the vendor's own response is retained"
  end

  test "coverage is stated in words, not just as a ratio" do
    # "10 of 11" invites the reader to assume the eleventh failed.
    coverage = cert.payload.fetch("coverage")

    assert_equal [ "voice" ], coverage.fetch("not_enabled_for_this_account")
    assert_equal 10, coverage.fetch("layers_expected")
    assert_equal 10, coverage.fetch("layers_answered")
    assert_in_delta 0.909, coverage.fetch("share_of_all_platform_layers"), 0.001
    assert_match(/must not be read as having passed/, coverage.fetch("note"))
  end

  test "a rejected lead is certified too" do
    # A buyer declining a lead needs evidence of why just as much - whether the
    # argument is with a regulator or with the seller who invoiced them.
    _account, rejected_lead = build_scenario("L-1005")
    rejected_run = verify!(rejected_lead)

    TenantScope.for_account(rejected_lead.account) do
      certificate = rejected_run.consent_certificate
      assert certificate.present?
      assert_equal "reject", certificate.payload.dig("verdict", "value")
      assert_equal "dnc_listed", certificate.payload.dig("verdict", "code")
      assert certificate.verify.valid?
    end
  end

  test "no certificate is issued for a run that could not be completed" do
    broke = build_account(public_id: "acct_broke", allowance: 3, consumed: 0)
    starved = build_lead(account: broke, pixel: build_pixel(account: broke))

    halted = verify!(starved)

    assert_equal "halted_insufficient_credits", halted.status
    TenantScope.for_account(broke) do
      assert_nil halted.consent_certificate,
                 "certifying a lead we did not finish checking is the liability we exist to remove"
    end
  end

  test "one certificate per run, even if finalising is retried" do
    TenantScope.for_account(cert_account) do
      verdict = Engine::Consensus.new(cert_run.consensus_policy).call(cert_run.engine_outcomes)
      again = Certificates::Issuer.call(run: cert_run, verdict: verdict)

      assert_equal cert.id, again.id
      assert_equal 1, ConsentCertificate.where(verification_run: cert_run).count
    end
  end

  test "serials are unguessable, since the serial is the verification credential" do
    serials = TenantScope.for_account(cert_account) do
      issuer = Certificates::Issuer.new(run: cert_run, verdict: nil)
      20.times.map { issuer.send(:generate_serial) }
    end

    assert_equal 20, serials.uniq.size
    assert serials.all? { |s| s.match?(/\ASPC-\d{6}-[A-Z0-9]{12}\z/) }
  end
end
