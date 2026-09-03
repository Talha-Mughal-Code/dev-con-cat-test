require "test_helper"

# The headline test for the consensus engine: all twelve seeded leads, evaluated
# end to end through the real evaluators and the real aggregator against the
# platform default policy.
#
# `expected_verdict` from mock-data/leads.json is used HERE and only here, as a
# test oracle. The engine has no access to it - it is stored on the Lead as
# `expected_verdict_hint`, and test_the_engine_cannot_read_the_hint asserts
# mechanically that nothing under app/ reads it.
#
# The suite is deliberately split into two passes, because cross-referencing
# leads.json against accounts.json turns up something the brief does not
# mention: THREE of the twelve scenarios are aimed at a layer the owning account
# has not enabled.
#
#   L-1003  VPN masking      -> acct_medicareedge has no vpn_proxy module
#   L-1005  litigator + DNC  -> acct_autoinsure has no blacklist_alliance module
#   L-1009  voice-actor fraud-> acct_autoinsure has no voice module
#
# So:
#
#   PASS 1 (full stack)     - every module enabled. Isolates the scoring model.
#                             All 12 match their hints.
#   PASS 2 (as provisioned) - each account's real enabled_modules. This is what
#                             the running system does. 11 of 12 match; L-1009
#                             lands REVIEW instead of REJECT, and that is the
#                             correct answer rather than a bug - see below.
class SeedLeadVerdictsTest < ActiveSupport::TestCase
  include EngineHarness

  # Hint vocabulary -> our verdict vocabulary. REJECT_DUPLICATE is a reject whose
  # reason happens to be a duplicate; the reason lives in verdict_code rather
  # than multiplying the verdict vocabulary.
  HINT_TO_VERDICT = {
    "ACCEPT" => "accept",
    "REVIEW" => "review",
    "REJECT" => "reject",
    "REJECT_DUPLICATE" => "reject"
  }.freeze

  ALL_MODULES = Engine::Registry::MODULE_KEYS

  # The single documented divergence under each account's real module set.
  AS_PROVISIONED_DIVERGENCES = {
    "L-1009" => {
      verdict: "review",
      because: "the voice module that would catch the reused voiceprint is not " \
               "enabled for acct_autoinsure, so the platform cannot claim voice fraud"
    }
  }.freeze

  # ---------------------------------------------------------------------------
  # Pass 1: full stack. Every layer available, so this tests the scoring model
  # alone, with module provisioning held constant.
  # ---------------------------------------------------------------------------
  MockData.leads.each do |lead_data|
    lead_id = lead_data["lead_id"]
    hint = lead_data["expected_verdict"]

    test "#{lead_id} derives #{hint} from provider signals with a full stack" do
      verdict = evaluate(lead_id, enabled: ALL_MODULES)
      expected = HINT_TO_VERDICT.fetch(hint)

      assert_equal expected, verdict.value, failure_message(lead_id, expected, verdict)
      # A verdict a buyer cannot explain is a verdict they cannot defend.
      assert verdict.reasons.any?, "#{lead_id} produced no reasons"
      assert verdict.code.present?, "#{lead_id} produced no verdict code"
    end
  end

  # ---------------------------------------------------------------------------
  # Pass 2: as provisioned. What the running system actually does.
  # ---------------------------------------------------------------------------
  MockData.leads.each do |lead_data|
    lead_id = lead_data["lead_id"]
    divergence = AS_PROVISIONED_DIVERGENCES[lead_id]
    expected = divergence ? divergence[:verdict] : HINT_TO_VERDICT.fetch(lead_data["expected_verdict"])
    suffix = divergence ? " (#{divergence[:because]})" : ""

    test "#{lead_id} yields #{expected} under its account's real module set#{suffix}" do
      verdict = evaluate(lead_id)
      assert_equal expected, verdict.value, failure_message(lead_id, expected, verdict)
    end
  end

  # ---------------------------------------------------------------------------
  # The three provisioning gaps, asserted explicitly. If a future seed change
  # enables these modules, these tests fail and force the divergence notes above
  # to be revisited rather than quietly rotting.
  # ---------------------------------------------------------------------------
  test "L-1003 is caught by Anura even though its account has no VPN module" do
    outcomes = outcomes_for(MockData.lead("L-1003"))
    vpn = outcomes.find { |o| o.module_key == "vpn_proxy" }

    assert_equal "not_enabled", vpn.state,
                 "acct_medicareedge is expected to have no vpn_proxy module"

    verdict = evaluate("L-1003")
    assert_equal "review", verdict.value
    # The consensus idea earning its keep: a second, independent voice covered
    # for the missing layer. Anura flagged ANONYMIZER_IP without being the
    # module bought for that job.
    assert_includes verdict.reasons.map { |r| r[:module] }, "anura"
    assert_match(/ANONYMIZER_IP/, verdict.primary_reason)
  end

  test "L-1005 still rejects via DNC despite having no litigator module" do
    outcomes = outcomes_for(MockData.lead("L-1005"))
    blacklist = outcomes.find { |o| o.module_key == "blacklist_alliance" }

    assert_equal "not_enabled", blacklist.state
    # Nothing about a not_enabled layer may look like a pass.
    assert_nil blacklist.assessment
    assert_nil blacklist.signal_state if blacklist.respond_to?(:signal_state)

    verdict = evaluate("L-1005")
    assert_equal "reject", verdict.value
    assert_equal "dnc_listed", verdict.code,
                 "with no litigator screening, DNC is the layer that saves this buyer"

    # And with the module they did not buy, the graver reason surfaces.
    with_litigator_screening = evaluate("L-1005", enabled: ALL_MODULES)
    assert_equal "litigator_confirmed", with_litigator_screening.code
    assert_includes with_litigator_screening.hard_stops.map { |hs| hs[:code] },
                    "litigator_confirmed"
  end

  test "L-1009 cannot claim voice fraud its account did not pay to detect" do
    outcomes = outcomes_for(MockData.lead("L-1009"))
    voice = outcomes.find { |o| o.module_key == "voice" }
    assert_equal "not_enabled", voice.state

    as_provisioned = evaluate("L-1009")
    # The honest answer on the evidence bought: a suspected fraud farm on a
    # churnable VoIP number is a lead a human should look at, not one the system
    # can dispositively reject.
    assert_equal "review", as_provisioned.value
    assert_includes as_provisioned.reasons.map { |r| r[:code] }, "suspect_fraud_farm"
    assert_includes as_provisioned.reasons.map { |r| r[:code] }, "all_voip"

    # Enable the module and the hinted verdict appears, from the hard stop the
    # scenario was written to exercise. The divergence is entirely about
    # provisioning, not about the scoring model.
    with_voice = evaluate("L-1009", enabled: ALL_MODULES)
    assert_equal "reject", with_voice.value
    assert_equal "voice_fraud", with_voice.code
  end

  # ---------------------------------------------------------------------------
  # Individual behaviours worth pinning down.
  # ---------------------------------------------------------------------------
  test "L-1004 rejects specifically because it is an exact CRM duplicate" do
    verdict = evaluate("L-1004")

    assert_equal "reject", verdict.value
    assert_equal "duplicate_hard", verdict.code
    assert_match(/ME-88213/, verdict.primary_reason)
  end

  test "L-1009 would still reject on weighted signals alone with a full stack" do
    # Not a lead that hangs on one clever layer: with voice removed from an
    # otherwise full stack, the remaining signals still clear the threshold.
    verdict = evaluate("L-1009", enabled: ALL_MODULES - [ "voice" ])

    assert_equal "reject", verdict.value
    assert_equal "risk_threshold", verdict.code
    assert_operator verdict.risk, :>=, 0.60
  end

  test "L-1012 accepts but surfaces the soft duplicate as an advisory" do
    verdict = evaluate("L-1012")

    assert_equal "accept", verdict.value
    assert_equal 1, verdict.advisories.size
    advisory = verdict.advisories.first
    assert_equal "soft_duplicate", advisory[:weight_key]
    assert_match(/AI-55019/, advisory[:message])
    # Priced below the accept threshold on purpose: a billing question, not a
    # fraud question.
    assert_operator verdict.risk, :<, 0.20
  end

  test "a soft duplicate plus any other doubt tips the same lead into review" do
    # L-1012 with one extra modest signal. The threshold placement does this on
    # its own - there is no special-casing anywhere for advisories.
    verdict = evaluate("L-1012", context_overrides: { form_dwell_ms: 4_000 })

    assert_equal "review", verdict.value
    assert_operator verdict.risk, :>=, 0.20
    codes = verdict.reasons.map { |r| r[:code] }
    assert_includes codes, "fast_fill"
    assert_includes codes, "soft_duplicate"
  end

  test "borderline review leads keep a real margin from the reject threshold" do
    # Guards against a future weight tweak silently flipping the REVIEW band into
    # rejections. Each should sit inside the band, not on its edge.
    %w[L-1003 L-1007 L-1011].each do |lead_id|
      verdict = evaluate(lead_id, enabled: ALL_MODULES)
      assert_equal "review", verdict.value, "#{lead_id} should be a review"
      assert_operator verdict.risk, :<, 0.58,
                      "#{lead_id} risk #{verdict.risk} is uncomfortably close to the reject threshold"
      assert_operator verdict.risk, :>=, 0.20,
                      "#{lead_id} risk #{verdict.risk} should not be accepted"
    end
  end

  test "the engine cannot read the expected_verdict hint" do
    # A grep-level guarantee. If anyone later reaches for the hint to make a
    # stubborn lead behave, this fails.
    offenders = Dir[Rails.root.join("app/**/*.rb")].select do |file|
      File.read(file).include?("expected_verdict")
    end

    assert_empty offenders,
                 "expected_verdict must never be referenced under app/ - found in #{offenders.inspect}"
  end

  private

  def failure_message(lead_id, expected, verdict)
    "#{lead_id} expected #{expected} but got #{verdict.value} " \
      "(risk #{verdict.risk}, code #{verdict.code}) - reasons: " \
      "#{verdict.reasons.map { |r| r[:message] }.join(' | ')}"
  end
end
