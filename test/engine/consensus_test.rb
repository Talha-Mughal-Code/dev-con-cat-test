require "test_helper"

# Unit tests for the aggregator's arithmetic and fail-safe behaviour, using
# synthetic findings so each rule is tested in isolation from any vendor's data.
class ConsensusTest < ActiveSupport::TestCase
  include EngineHarness
  include SyntheticOutcomes

  def verdict_for(outcomes, rules = {})
    Engine::Consensus.new(policy(rules)).call(outcomes)
  end

  # --- the arithmetic -------------------------------------------------------

  test "combines independent layers with noisy-OR rather than a sum" do
    # Two 0.35 signals from different layers. A sum would give 0.70 and reject;
    # noisy-OR gives 1 - (0.65 * 0.65) = 0.5775 and holds the lead for review.
    # That saturation is the whole reason for the choice.
    outcomes = [
      answered("email_validation",
               findings: [ synthetic_finding(module_key: "email_validation",
                                             weight_key: "consensus_undeliverable") ]),
      answered("vpn_proxy",
               findings: [ synthetic_finding(module_key: "vpn_proxy",
                                             weight_key: "anonymizer_with_ip_mismatch") ])
    ]

    verdict = verdict_for(outcomes)

    assert_in_delta 0.5775, verdict.risk, 0.0001
    assert_equal "review", verdict.value
  end

  test "takes the maximum contribution within one layer, not the sum" do
    # An address that is undeliverable AND disposable AND high-fraud-score is
    # three correlated observations from one source. Summing them (0.35 + 0.30 +
    # 0.15) would reject; one voice gets one vote at its strongest objection.
    outcomes = [
      answered("email_validation", findings: [
        synthetic_finding(module_key: "email_validation", weight_key: "consensus_undeliverable"),
        synthetic_finding(module_key: "email_validation", weight_key: "disposable"),
        synthetic_finding(module_key: "email_validation", weight_key: "elevated_fraud_score")
      ])
    ]

    verdict = verdict_for(outcomes)

    assert_in_delta 0.35, verdict.risk, 0.0001
    assert_equal "review", verdict.value
  end

  test "risk is independent of the order layers finish in" do
    # Layers land as background jobs complete, so a verdict that depended on
    # ordering would be non-deterministic in production.
    findings = [
      answered("anura", findings: [ synthetic_finding(module_key: "anura", weight_key: "suspect") ]),
      answered("phone_validation", findings: [ synthetic_finding(module_key: "phone_validation",
                                                                 weight_key: "validity_disagreement") ]),
      answered("vpn_proxy", findings: [ synthetic_finding(module_key: "vpn_proxy",
                                                          weight_key: "elevated_risk") ])
    ]

    risks = findings.permutation.map { |ordering| verdict_for(ordering).risk }

    assert_equal 1, risks.uniq.size, "risk varied with layer ordering: #{risks.inspect}"
  end

  test "a clean sweep accepts with zero risk" do
    outcomes = Engine::Registry::MODULE_KEYS.map { |key| answered(key) }
    verdict = verdict_for(outcomes)

    assert_equal "accept", verdict.value
    assert_equal "clean", verdict.code
    assert_in_delta 0.0, verdict.risk, 0.0001
    assert_in_delta 1.0, verdict.confidence, 0.0001
  end

  # --- hard stops -----------------------------------------------------------

  test "an armed hard stop rejects regardless of how clean everything else is" do
    outcomes = [
      answered("dnc", findings: [ synthetic_finding(module_key: "dnc", hard_stop_code: "dnc_listed",
                                                    weight_key: "listed") ], fail_closed: true)
    ] + (Engine::Registry::MODULE_KEYS - [ "dnc" ]).map { |key| answered(key) }

    verdict = verdict_for(outcomes)

    assert_equal "reject", verdict.value
    assert_equal "dnc_listed", verdict.code
    # A hard stop bypasses scoring entirely - that is what makes it hard.
    assert_in_delta 1.0, verdict.risk, 0.0001
    assert verdict.hard_stopped?
  end

  test "hard stops report the gravest reason when several fire at once" do
    outcomes = [
      answered("dnc", findings: [ synthetic_finding(module_key: "dnc", hard_stop_code: "dnc_listed") ]),
      answered("blacklist_alliance",
               findings: [ synthetic_finding(module_key: "blacklist_alliance",
                                             hard_stop_code: "litigator_confirmed") ]),
      answered("duplicate_detection",
               findings: [ synthetic_finding(module_key: "duplicate_detection",
                                             hard_stop_code: "duplicate_hard") ])
    ]

    verdict = verdict_for(outcomes)

    assert_equal "litigator_confirmed", verdict.code
    assert_equal 3, verdict.hard_stops.size, "every hard stop is still recorded as a reason"
  end

  test "suspected litigator is a weighted signal by default and lands in review" do
    outcomes = [
      answered("blacklist_alliance",
               findings: [ synthetic_finding(module_key: "blacklist_alliance",
                                             hard_stop_code: "litigator_suspected",
                                             weight_key: "suspected") ])
    ]

    verdict = verdict_for(outcomes)

    assert_equal "review", verdict.value
    assert_in_delta 0.30, verdict.risk, 0.0001
    assert_empty verdict.hard_stops
  end

  test "a buyer can arm suspected litigator as a hard stop with data alone" do
    # This is the exact tuning docs/DESIGN_QUESTIONS.md asks about. No deploy,
    # no code change - one boolean in the policy document.
    outcomes = [
      answered("blacklist_alliance",
               findings: [ synthetic_finding(module_key: "blacklist_alliance",
                                             hard_stop_code: "litigator_suspected",
                                             weight_key: "suspected") ])
    ]

    verdict = verdict_for(outcomes, "hard_stops" => { "litigator_suspected" => { "enabled" => true } })

    assert_equal "reject", verdict.value
    assert_equal "litigator_suspected", verdict.code
  end

  test "disarming a hard stop leaves a heavy weight, not a free pass" do
    outcomes = [
      answered("dnc", findings: [ synthetic_finding(module_key: "dnc", hard_stop_code: "dnc_listed",
                                                    weight_key: "listed") ])
    ]
    rules = { "hard_stops" => { "dnc_listed" => { "enabled" => false } } }

    verdict = verdict_for(outcomes, rules)

    # Still rejects on its own at 0.65, but is now combinable with and
    # overridable by other evidence instead of being dispositive.
    assert_equal "reject", verdict.value
    assert_equal "risk_threshold", verdict.code
    assert_in_delta 0.65, verdict.risk, 0.0001
    assert_empty verdict.hard_stops
  end

  # --- the three layer states ----------------------------------------------

  test "not_enabled and not_applicable are excluded from coverage and scoring" do
    outcomes = [
      answered("anura"),
      unanswered("voice", "not_applicable"),
      unanswered("enrichment", "not_enabled")
    ]

    verdict = verdict_for(outcomes)

    assert_equal "accept", verdict.value
    # Only the layer that could speak counts in the denominator.
    assert_equal 1, verdict.coverage[:expected]
    assert_equal 1, verdict.coverage[:answered]
    assert_in_delta 1.0, verdict.coverage[:ratio], 0.0001
    # But breadth records that only one of three was actually checked, so the
    # certificate cannot imply a thorough review.
    assert_in_delta 0.3333, verdict.coverage[:breadth], 0.0001
    assert_equal [ "enrichment" ], verdict.coverage[:not_enabled]
    assert_equal [ "voice" ], verdict.coverage[:not_applicable]
  end

  test "a layer that did not answer never contributes a signal" do
    %w[not_enabled not_applicable errored timed_out skipped_insufficient_credits].each do |state|
      outcome = unanswered("anura", state)
      assert_empty outcome.findings, "#{state} must yield no findings"
    end
  end

  # --- unavailability: fail open vs fail closed ----------------------------

  test "an unavailable fail-closed layer fails closed and caps at review" do
    outcomes = [
      unanswered("trustedform", "errored", fail_closed: true)
    ] + (Engine::Registry::MODULE_KEYS - [ "trustedform" ]).map { |key| answered(key) }

    verdict = verdict_for(outcomes)

    # Everything else passed, so the score alone would accept.
    assert_in_delta 0.0, verdict.weighted_risk, 0.0001
    assert_equal "review", verdict.value
    assert_equal "fail_closed_layer_unavailable", verdict.code
  end

  test "an unavailable non-critical layer fails open and still accepts" do
    outcomes = [
      unanswered("enrichment", "errored")
    ] + (Engine::Registry::MODULE_KEYS - [ "enrichment" ]).map { |key| answered(key) }

    verdict = verdict_for(outcomes)

    assert_equal "accept", verdict.value
    assert_equal [ "enrichment" ], verdict.coverage[:unavailable]
  end

  test "an unavailable layer never turns a clean lead into a rejection" do
    # A vendor outage is not the lead's fault. Rejecting on it would destroy
    # good leads the buyer has already paid for.
    outcomes = Engine::Registry::MODULE_KEYS.map do |key|
      unanswered(key, "errored", fail_closed: %w[trustedform dnc].include?(key))
    end

    verdict = verdict_for(outcomes)

    assert_not_equal "reject", verdict.value
    assert_equal "review", verdict.value
  end

  test "coverage below the policy floor caps an otherwise clean lead at review" do
    answered_layers = Engine::Registry::MODULE_KEYS.first(3).map { |key| answered(key) }
    missing_layers = Engine::Registry::MODULE_KEYS.drop(3).map { |key| unanswered(key, "timed_out") }

    verdict = verdict_for(answered_layers + missing_layers)

    assert_equal "review", verdict.value
    assert_includes [ "insufficient_coverage", "fail_closed_layer_unavailable" ], verdict.code
    assert_operator verdict.coverage[:ratio], :<, 0.5
  end

  test "a hard stop still rejects even when coverage is far below the floor" do
    # Caps only ever downgrade an accept. They must never soften a hard stop.
    outcomes = [
      answered("dnc", findings: [ synthetic_finding(module_key: "dnc",
                                                    hard_stop_code: "dnc_listed") ])
    ] + (Engine::Registry::MODULE_KEYS - [ "dnc" ]).map { |key| unanswered(key, "errored") }

    verdict = verdict_for(outcomes)

    assert_equal "reject", verdict.value
    assert_equal "dnc_listed", verdict.code
  end

  # --- thresholds -----------------------------------------------------------

  test "thresholds are inclusive at reject and exclusive at accept" do
    boundary = ->(weight) do
      verdict_for([ answered("anura", findings: [ synthetic_finding(module_key: "anura",
                                                                    weight_key: "custom") ]) ],
                  "weights" => { "anura" => { "custom" => weight } })
    end

    assert_equal "accept", boundary.call(0.1999).value
    assert_equal "review", boundary.call(0.20).value, "accept_below must be exclusive"
    assert_equal "review", boundary.call(0.5999).value
    assert_equal "reject", boundary.call(0.60).value, "reject_at_or_above must be inclusive"
  end

  test "a buyer can retune thresholds without touching code" do
    outcomes = [
      answered("anura", findings: [ synthetic_finding(module_key: "anura", weight_key: "suspect") ])
    ]

    # 0.30 risk: review by default, rejected by a stricter buyer, accepted by a
    # more permissive one.
    assert_equal "review", verdict_for(outcomes).value
    assert_equal "reject", verdict_for(outcomes, "thresholds" => { "reject_at_or_above" => 0.25 }).value
    assert_equal "accept", verdict_for(outcomes, "thresholds" => { "accept_below" => 0.40 }).value
  end

  test "a partial weight override does not zero out the weights it omits" do
    # Policies inherit from the platform default rather than replacing it, so an
    # account that tunes one number does not silently disable everything else.
    outcomes = [
      answered("anura", findings: [ synthetic_finding(module_key: "anura", weight_key: "suspect") ]),
      answered("phone_validation",
               findings: [ synthetic_finding(module_key: "phone_validation",
                                             weight_key: "majority_invalid") ])
    ]

    verdict = verdict_for(outcomes, "weights" => { "anura" => { "suspect" => 0.10 } })

    # anura overridden to 0.10, phone still at its default 0.40.
    assert_in_delta 0.46, verdict.risk, 0.0001
  end

  # --- explanations ---------------------------------------------------------

  test "every verdict carries an ordered explanation" do
    outcomes = [
      answered("anura", findings: [ synthetic_finding(module_key: "anura", weight_key: "suspect",
                                                      detail: "flagged suspect") ]),
      answered("phone_validation",
               findings: [ synthetic_finding(module_key: "phone_validation",
                                             weight_key: "majority_invalid",
                                             detail: "2 of 3 say unreachable") ]),
      answered("duplicate_detection",
               findings: [ synthetic_finding(module_key: "duplicate_detection",
                                             weight_key: "soft_duplicate", advisory: true,
                                             detail: "possible duplicate") ])
    ]

    verdict = verdict_for(outcomes)
    signals = verdict.reasons.select { |r| r[:severity] == "signal" }

    # Heaviest signal first, so the primary reason is the one that mattered most.
    assert_equal "majority_invalid", signals.first[:code]
    assert_equal %w[majority_invalid suspect], signals.map { |r| r[:code] }
    # Advisories are reported separately from fraud signals.
    assert_equal 1, verdict.advisories.size
    assert_equal "advisory", verdict.reasons.find { |r| r[:code] == "soft_duplicate" }[:severity]
  end

  test "an accept explains itself rather than saying nothing" do
    verdict = verdict_for(Engine::Registry::MODULE_KEYS.map { |key| answered(key) })

    assert_equal 1, verdict.reasons.size
    assert_equal "clean", verdict.reasons.first[:code]
    assert_match(/every enabled layer/i, verdict.reasons.first[:message])
  end
end
