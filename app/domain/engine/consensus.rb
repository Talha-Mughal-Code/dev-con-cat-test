module Engine
  # Turns N layer voices into one verdict.
  #
  # This class knows about thresholds and weights and nothing whatsoever about
  # vendors - the evaluators already translated their responses into findings.
  #
  # THE ARITHMETIC
  # --------------
  # Within a layer: take the MAXIMUM contribution, not the sum. A layer is one
  # voice, and it gets one vote at the weight of its strongest objection. An
  # email address that is both disposable and undeliverable is two correlated
  # observations from one source, not two independent ones - and taking the max
  # also removes any incentive to game the weights by splitting one condition
  # into three.
  #
  # Across layers: noisy-OR.
  #
  #     risk = 1 - Π(1 - contribution_i)
  #
  # Chosen over a weighted sum for two reasons. It is the probabilistic reading
  # of the brief's own metaphor - independent imperfect detectors each raising
  # doubt - and it saturates correctly. Two 0.35 signals give 0.58, not 0.70: a
  # second dissenting voice matters, but no amount of stacking can add its way
  # past a threshold the way an additive model can. It is also monotonic and
  # order-independent, so the verdict never depends on which job finished first.
  #
  # THE DECISION
  # ------------
  #   1. Any ARMED hard stop            -> REJECT (bypasses the score entirely)
  #   2. risk >= reject_at_or_above      -> REJECT
  #   3. risk <  accept_below            -> ACCEPT, unless capped
  #   4. otherwise                       -> REVIEW
  #
  # Two things cap an ACCEPT down to REVIEW, and neither can ever cause a
  # REJECT, because a vendor outage is not the lead's fault:
  #
  #   * a fail-closed layer that was enabled but could not answer
  #     (we will not vouch for something we did not check)
  #   * coverage below the policy floor
  #     (we will not vouch for a lead we barely checked)
  class Consensus
    def initialize(policy)
      @policy = policy
    end

    def call(outcomes)
      contributions = outcomes.index_with { |outcome| resolve(outcome) }
      hard_stops = contributions.values.flat_map { |c| c[:hard_stops] }
      advisories = contributions.values.flat_map { |c| c[:advisories] }

      weighted_risk = noisy_or(contributions.values.map { |c| c[:risk] })
      coverage = measure_coverage(outcomes)
      caps = capping_constraints(outcomes, coverage)

      value, code = decide(hard_stops, weighted_risk, caps)
      risk = hard_stops.any? ? 1.0 : weighted_risk

      Verdict.new(
        value: value,
        code: code,
        risk: risk,
        weighted_risk: weighted_risk,
        confidence: (1.0 - risk).round(4),
        reasons: build_reasons(value, code, hard_stops, contributions, advisories, caps, weighted_risk),
        layer_contributions: contributions,
        hard_stops: hard_stops,
        advisories: advisories,
        coverage: coverage
      )
    end

    private

    attr_reader :policy

    # Resolve one layer's findings against the policy. This is the only place a
    # finding learns whether it is dispositive and what it is worth.
    def resolve(outcome)
      hard_stops = []
      advisories = []
      weighted = []

      outcome.findings.each do |found|
        if found.dispositive_candidate? && policy.hard_stop_enabled?(found.hard_stop_code)
          hard_stops << {
            code: found.hard_stop_code,
            module_key: found.module_key,
            message: found.detail,
            headline: HardStops.find(found.hard_stop_code).headline
          }
          next
        end

        weight = weight_for(found)
        next if weight.zero?

        entry = { module_key: found.module_key, weight_key: found.weight_key,
                  weight: weight, message: found.detail, advisory: found.advisory? }
        weighted << entry
        advisories << entry if found.advisory?
      end

      {
        state: outcome.state,
        # Maximum, not sum - see the class comment.
        risk: weighted.map { |w| w[:weight] }.max || 0.0,
        signal: signal_for(outcome, hard_stops, weighted),
        hard_stops: hard_stops,
        advisories: advisories,
        weighted: weighted.sort_by { |w| -w[:weight] },
        summary: outcome.answered? ? outcome.assessment&.summary : nil
      }
    end

    # A disarmed hard stop must not become free, so it falls back to a weight
    # listed under weights.disarmed_hard_stops before the module's own weights.
    # Those fallbacks sit above the REJECT threshold, so the condition still
    # rejects on its own - but it is now combinable with, and overridable by,
    # other evidence. That is exactly the difference between "dispositive" and
    # "very heavy".
    def weight_for(found)
      if found.dispositive_candidate?
        fallback = policy.weight_for("disarmed_hard_stops", found.hard_stop_code)
        return fallback.to_f if fallback.to_f.positive?
      end

      return 0.0 if found.weight_key.blank?

      policy.weight_for(found.module_key, found.weight_key).to_f
    end

    def signal_for(outcome, hard_stops, weighted)
      return nil unless outcome.answered?
      return "fail" if hard_stops.any?
      return "warn" if weighted.any?

      "pass"
    end

    def noisy_or(contributions)
      product = contributions.reduce(1.0) { |acc, c| acc * (1.0 - c.to_f.clamp(0.0, 1.0)) }
      (1.0 - product).round(4)
    end

    def measure_coverage(outcomes)
      expected = outcomes.count(&:expected?)
      answered = outcomes.count(&:answered?)
      # Two different questions, reported separately on purpose:
      #   ratio   - did we get the answers we expected? (gates ACCEPT)
      #   breadth - how thorough was the check overall? (context on the
      #             certificate; a buyer on a thin plan has low breadth without
      #             anything having gone wrong)
      {
        expected: expected,
        answered: answered,
        ratio: expected.zero? ? 1.0 : (answered.to_f / expected).round(4),
        breadth: outcomes.size.zero? ? 0.0 : (answered.to_f / outcomes.size).round(4),
        not_enabled: outcomes.select { |o| o.state == "not_enabled" }.map(&:module_key),
        not_applicable: outcomes.select { |o| o.state == "not_applicable" }.map(&:module_key),
        unavailable: outcomes.select { |o| o.state.in?(%w[errored timed_out]) }.map(&:module_key),
        skipped_for_credits: outcomes.select { |o| o.state == "skipped_insufficient_credits" }.map(&:module_key)
      }
    end

    def capping_constraints(outcomes, coverage)
      caps = []

      missing_required = outcomes.select { |o| o.fail_closed? && o.expected? && o.missing? }
      if missing_required.any?
        caps << {
          code: "fail_closed_layer_unavailable",
          message: "#{missing_required.map(&:module_key).to_sentence} could not be checked. " \
                   "That layer fails closed, so this lead cannot be accepted."
        }
      end

      if coverage[:ratio] < policy.coverage_floor
        caps << {
          code: "insufficient_coverage",
          message: "Only #{coverage[:answered]} of #{coverage[:expected]} expected layers answered " \
                   "(#{(coverage[:ratio] * 100).round}%, floor #{(policy.coverage_floor * 100).round}%). " \
                   "Not enough evidence to vouch for this lead."
        }
      end

      caps
    end

    def decide(hard_stops, risk, caps)
      # A hard stop bypasses the score. Nothing offsets it - that is what makes
      # it a hard stop rather than a large weight.
      return [ "reject", primary_hard_stop_code(hard_stops) ] if hard_stops.any?
      return [ "reject", "risk_threshold" ] if risk >= policy.reject_at_or_above

      if risk < policy.accept_below
        # Caps can only ever downgrade an ACCEPT to a REVIEW. They never reject:
        # a vendor outage is not the lead's fault, and rejecting on it would
        # destroy good leads the buyer has already paid for.
        return [ "review", caps.first[:code] ] if caps.any?

        return [ "accept", "clean" ]
      end

      [ "review", "risk_threshold" ]
    end

    # When several hard stops fire, name the one with the gravest consequence.
    # HardStops::ALL is ordered by that consequence - legal exposure first.
    def primary_hard_stop_code(hard_stops)
      codes = hard_stops.map { |hs| hs[:code] }
      HardStops::CODES.find { |code| codes.include?(code) } || codes.first
    end

    def build_reasons(value, code, hard_stops, contributions, advisories, caps, weighted_risk)
      reasons = []

      hard_stops.each do |stop|
        reasons << { code: stop[:code], module: stop[:module_key], severity: "hard_stop",
                     message: stop[:message] }
      end

      contributions.each_value do |contribution|
        contribution[:weighted].reject { |w| w[:advisory] }.each do |w|
          reasons << { code: w[:weight_key], module: w[:module_key], severity: "signal",
                       weight: w[:weight], message: w[:message] }
        end
      end
      # Signals ordered by how much they actually moved the number.
      signals = reasons.select { |r| r[:severity] == "signal" }.sort_by { |r| -r[:weight].to_f }
      reasons = reasons.select { |r| r[:severity] == "hard_stop" } + signals

      advisories.each do |advisory|
        reasons << { code: advisory[:weight_key], module: advisory[:module_key], severity: "advisory",
                     weight: advisory[:weight], message: advisory[:message] }
      end

      caps.each do |cap|
        reasons << { code: cap[:code], severity: "constraint", message: cap[:message] }
      end

      if reasons.empty?
        reasons << { code: "clean", severity: "info",
                     message: "Every enabled layer that applied to this lead returned a pass." }
      elsif value != "reject" && hard_stops.empty?
        reasons << { code: "score", severity: "info",
                     message: "Combined risk #{(weighted_risk * 100).round}% " \
                              "(accept below #{(policy.accept_below * 100).round}%, " \
                              "reject at #{(policy.reject_at_or_above * 100).round}%)." }
      end

      reasons
    end
  end
end
