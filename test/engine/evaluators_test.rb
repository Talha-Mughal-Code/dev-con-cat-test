require "test_helper"

# Evaluators translate a vendor response into our vocabulary. These tests cover
# the translations where getting it wrong would be invisible in the aggregate:
# independent verification of consent, applicability, and the consensus layers
# where "what did they agree on" is the whole question.
class EvaluatorsTest < ActiveSupport::TestCase
  include EngineHarness

  def context(overrides = {})
    build_lead_context(MockData.lead("L-1001"), overrides)
  end

  def evaluate_layer(module_key, payload, ctx = context)
    Engine::Registry.for(module_key).call(payload, ctx)
  end

  # --- TrustedForm: we verify the claim, we do not trust the status ---------

  test "a cert whose phone does not match the lead cannot prove consent" do
    # Note the vendor still says "verified". docs/provider-modules.md lists four
    # things to check, so all four are checked rather than deferring to a summary
    # field - otherwise the one layer the product rests on is the one layer we
    # never actually verify.
    payload = {
      "status" => "verified", "matches_phone" => false, "matches_email" => true,
      "page_url" => "https://solar-savings.example.com/quote",
      "consent_language_present" => true,
      "expires_at" => 1.year.from_now.iso8601
    }

    assessment = evaluate_layer("trustedform", payload)

    assert_equal 1, assessment.findings.size
    assert_equal "consent_unverifiable", assessment.findings.first.hard_stop_code
    assert_match(/phone does not match/, assessment.findings.first.detail)
  end

  test "a cert whose page fingerprint differs from the claimed landing page fails" do
    payload = {
      "status" => "verified", "matches_phone" => true, "matches_email" => true,
      "page_url" => "https://unrelated-offers.example.com/win",
      "consent_language_present" => true, "expires_at" => 1.year.from_now.iso8601
    }

    assessment = evaluate_layer("trustedform", payload)

    assert_equal "consent_unverifiable", assessment.findings.first.hard_stop_code
    assert_match(/page fingerprint/, assessment.findings.first.detail)
  end

  test "trailing slashes and case do not count as a page mismatch" do
    payload = {
      "status" => "verified", "matches_phone" => true, "matches_email" => true,
      "page_url" => "HTTPS://Solar-Savings.example.com/quote/",
      "consent_language_present" => true, "expires_at" => 1.year.from_now.iso8601
    }

    assert_empty evaluate_layer("trustedform", payload).findings
  end

  test "cert expiry is judged at capture time, not at verification time" do
    captured = Time.zone.parse("2026-07-14T15:02:11Z")

    # Valid when the person actually submitted the form, expiring later. Consent
    # given today is not retroactively invalidated by a cert lapsing next month.
    still_valid = {
      "status" => "verified", "matches_phone" => true, "matches_email" => true,
      "page_url" => "https://solar-savings.example.com/quote",
      "consent_language_present" => true, "expires_at" => (captured + 1.day).iso8601
    }
    assert_empty evaluate_layer("trustedform", still_valid, context(captured_at: captured)).findings

    # Already lapsed before capture: there was no valid consent record at the
    # moment it mattered.
    already_expired = still_valid.merge("expires_at" => (captured - 1.day).iso8601)
    assessment = evaluate_layer("trustedform", already_expired, context(captured_at: captured))
    assert_equal "consent_unverifiable", assessment.findings.first.hard_stop_code
    assert_match(/already expired at capture/, assessment.findings.first.detail)
  end

  test "a missing certificate is not a pass" do
    assessment = evaluate_layer("trustedform", { "status" => "not_found" })

    assert_equal "consent_unverifiable", assessment.findings.first.hard_stop_code
    assert_match(/no retained certificate/, assessment.findings.first.detail)
  end

  test "a valid cert on a page with no consent language is a weighted signal" do
    payload = {
      "status" => "verified", "matches_phone" => true, "matches_email" => true,
      "page_url" => "https://solar-savings.example.com/quote",
      "consent_language_present" => false, "expires_at" => 1.year.from_now.iso8601
    }

    finding = evaluate_layer("trustedform", payload).findings.sole

    assert_nil finding.hard_stop_code, "there is a retained cert, so this is not dispositive"
    assert_equal "consent_language_absent", finding.weight_key
  end

  # --- applicability -------------------------------------------------------

  test "voice does not apply to a lead with no sample" do
    evaluator = Engine::Registry.for("voice")

    assert_not evaluator.applicable?({ "has_sample" => false, "verdict" => nil }, context)
    assert_not evaluator.applicable?({}, context)
    assert evaluator.applicable?({ "has_sample" => true, "verdict" => "human_unique" }, context)
  end

  test "voice fraud names the identities the voiceprint was reused across" do
    payload = MockData.provider_payload("voice", "L-1009")
    finding = evaluate_layer("voice", payload).findings.sole

    assert_equal "voice_fraud", finding.hard_stop_code
    assert_match(/vp_41fe/, finding.detail)
    assert_match(/3 other identities/, finding.detail)
  end

  # --- phone consensus ------------------------------------------------------

  test "phone providers disagreeing about existence outweighs disagreeing about line type" do
    validity_split = { "providers" => {
      "twilio_lookup" => { "valid" => true, "line_type" => "mobile" },
      "numverify" => { "valid" => false, "line_type" => "unknown" },
      "telesign" => { "valid" => true, "line_type" => "mobile" }
    } }
    line_type_split = { "providers" => {
      "twilio_lookup" => { "valid" => true, "line_type" => "landline" },
      "numverify" => { "valid" => true, "line_type" => "mobile" },
      "telesign" => { "valid" => true, "line_type" => "landline" }
    } }

    assert_equal "validity_disagreement",
                 evaluate_layer("phone_validation", validity_split).findings.sole.weight_key
    assert_equal "line_type_disagreement",
                 evaluate_layer("phone_validation", line_type_split).findings.sole.weight_key
  end

  test "a majority saying unreachable is stronger than a bare disagreement" do
    payload = MockData.provider_payload("phone_validation", "L-1002")
    finding = evaluate_layer("phone_validation", payload).findings.sole

    assert_equal "majority_invalid", finding.weight_key
    assert_match(/2 of 3/, finding.detail)
  end

  test "unanimous VoIP is flagged even though every provider says valid" do
    payload = MockData.provider_payload("phone_validation", "L-1009")
    finding = evaluate_layer("phone_validation", payload).findings.sole

    assert_equal "all_voip", finding.weight_key
    assert_match(/TextNow/, finding.detail)
  end

  test "unanimous agreement on a real mobile number produces no findings" do
    payload = MockData.provider_payload("phone_validation", "L-1001")
    assessment = evaluate_layer("phone_validation", payload)

    assert_empty assessment.findings
    assert assessment.breakdown.dig("agreement", "unanimous")
  end

  # --- email consensus ------------------------------------------------------

  test "both providers agreeing undeliverable is stronger than a split" do
    both = MockData.provider_payload("email_validation", "L-1008")
    split = { "providers" => {
      "zerobounce" => { "deliverable" => true, "disposable" => false, "fraud_score" => 10 },
      "neverbounce" => { "deliverable" => false, "disposable" => false, "fraud_score" => 20 }
    } }

    assert_equal "consensus_undeliverable",
                 evaluate_layer("email_validation", both).findings.first.weight_key
    assert_equal "providers_disagree",
                 evaluate_layer("email_validation", split).findings.first.weight_key
  end

  test "the disposable bot address trips several conditions at once" do
    payload = MockData.provider_payload("email_validation", "L-1002")
    keys = evaluate_layer("email_validation", payload).findings.map(&:weight_key)

    # All recorded as evidence; Consensus then takes the maximum, because these
    # are correlated observations from one source.
    assert_equal %w[consensus_undeliverable disposable elevated_fraud_score], keys
  end

  # --- enrichment cross-validation -----------------------------------------

  test "enrichment sources contradicting each other is a flag" do
    payload = MockData.provider_payload("enrichment", "L-1011")
    keys = evaluate_layer("enrichment", payload).findings.map(&:weight_key)

    assert_includes keys, "sources_disagree"
    assert_includes keys, "identity_mismatch"
  end

  test "one source resolving and one failing is thinner evidence, not bad evidence" do
    payload = MockData.provider_payload("enrichment", "L-1009")
    finding = evaluate_layer("enrichment", payload).findings.sole

    assert_equal "single_source", finding.weight_key
    assert_match(/bytemine/, finding.detail)
  end

  test "address formatting differences are not treated as disagreement" do
    payload = {
      "audiencelabs" => { "matched" => true, "address" => "418 Maple Ave, Los Angeles, CA 90012",
                          "age_band" => "35-44", "match_to_lead" => true },
      "bytemine" => { "matched" => true, "address" => "418 maple ave., los angeles ca 90012",
                      "age_band" => "35-44", "match_to_lead" => true }
    }

    assert_empty evaluate_layer("enrichment", payload).findings
  end

  # --- first-party capture behaviour ---------------------------------------

  test "an uncaptured consent checkbox is silent, an unticked one is a signal" do
    # The tri-state distinction. Penalising a lead for consent it was never asked
    # to give would flag every seeded lead in the fixtures.
    assert_empty evaluate_layer("capture_behaviour", {}, context(consent_checkbox: nil)).findings

    finding = evaluate_layer("capture_behaviour", {}, context(consent_checkbox: false)).findings.sole
    assert_equal "consent_declined", finding.weight_key

    assert_empty evaluate_layer("capture_behaviour", {}, context(consent_checkbox: true)).findings
  end

  test "dwell time is graded rather than binary" do
    grade = ->(ms) do
      evaluate_layer("capture_behaviour", {}, context(form_dwell_ms: ms)).findings.first&.weight_key
    end

    assert_equal "instant_fill", grade.call(640)
    assert_equal "fast_fill", grade.call(4_000)
    # Autofill is innocent, so the band above is priced low and the band above
    # that is silent.
    assert_nil grade.call(20_000)
  end

  # --- duplicate matching ---------------------------------------------------

  test "phone and email both matching is an exact duplicate" do
    result = Providers::DuplicateMatcher
             .new(crm_matcher_records("acct_medicareedge"))
             .match(build_lead_context(MockData.lead("L-1004")))

    assert_equal "exact", result["match_type"]
    assert_equal "ME-88213", result["matches"].sole["reference"]
    assert_equal %w[phone email], result["matches"].sole["matched_on"]
  end

  test "phone matching with a different email is a partial duplicate" do
    result = Providers::DuplicateMatcher
             .new(crm_matcher_records("acct_autoinsure"))
             .match(build_lead_context(MockData.lead("L-1012")))

    assert_equal "partial", result["match_type"]
    assert_equal [ "phone" ], result["matches"].sole["matched_on"]
  end

  test "duplicate matching never crosses an account boundary" do
    # L-1004's twin lives in acct_medicareedge. Searched against another
    # account's records it must not match, or a buyer would be denied a lead
    # because a competitor already owns it.
    result = Providers::DuplicateMatcher
             .new(crm_matcher_records("acct_solarpro"))
             .match(build_lead_context(MockData.lead("L-1004")))

    assert_equal "none", result["match_type"]
    assert_empty result["matches"]
  end

  test "a lead with no contact details matches nothing" do
    result = Providers::DuplicateMatcher
             .new(crm_matcher_records("acct_medicareedge"))
             .match(build_lead_context(MockData.lead("L-1004"),
                                       email_normalized: nil, phone_normalized: nil))

    assert_equal "none", result["match_type"]
  end
end
