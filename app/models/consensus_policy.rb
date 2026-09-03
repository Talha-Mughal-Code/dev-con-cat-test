# The tunable half of the consensus engine.
#
# Deliberate split between code and data:
#
#   * The VOCABULARY of dispositive conditions is code - a named set of
#     hard-stop predicates in Engine::HardStops. Code, because each one encodes
#     a legal or economic claim ("a confirmed TCPA plaintiff must never be
#     dialled") that has to be reviewable, testable, and impossible to express
#     malformedly through a settings screen.
#
#   * Which of those predicates are ARMED, every weight, and every threshold is
#     DATA in the `rules` document below. So the tuning the brief asks about -
#     "treat suspected litigator as a hard stop" - is flipping
#     hard_stops.litigator_suspected.enabled to true. No deploy.
#
# A row with account_id NULL is the platform default that every account
# inherits; an account row overrides it. Inheritance rather than a per-account
# copy means a platform-level correction reaches everyone who has not
# deliberately diverged.
class ConsensusPolicy < ApplicationRecord
  belongs_to :account, optional: true

  json_attribute :rules, default: {}

  validates :name, presence: true
  validates :version, presence: true, uniqueness: { scope: :account_id }
  validate  :rules_are_well_formed

  scope :platform, -> { where(account_id: nil) }

  def self.platform_default
    platform.where(active: true).order(version: :desc).first
  end

  def platform_default? = account_id.nil?

  def thresholds
    defaults = DEFAULT_RULES.fetch("thresholds")
    defaults.merge(rules.fetch("thresholds", {}))
  end

  def accept_below        = thresholds.fetch("accept_below").to_f
  def reject_at_or_above  = thresholds.fetch("reject_at_or_above").to_f

  # Fraction of applicable, enabled layers that must actually have answered
  # before an ACCEPT is allowed. Below it we can still reject (a hard stop is a
  # hard stop) but we will not vouch for a lead we barely checked.
  def coverage_floor = thresholds.fetch("coverage_floor").to_f

  def hard_stop_enabled?(code)
    config = rules.dig("hard_stops", code.to_s) ||
             DEFAULT_RULES.dig("hard_stops", code.to_s) || {}
    config.fetch("enabled", false)
  end

  def enabled_hard_stops
    Engine::HardStops::CODES.select { |code| hard_stop_enabled?(code) }
  end

  # Weight for one named condition within one layer. Falls back to the platform
  # default so a partial override does not silently zero out everything it
  # failed to mention.
  def weight_for(module_key, condition)
    rules.dig("weights", module_key.to_s, condition.to_s) ||
      DEFAULT_RULES.dig("weights", module_key.to_s, condition.to_s) ||
      0.0
  end

  def weights_for(module_key)
    DEFAULT_RULES.fetch("weights", {}).fetch(module_key.to_s, {})
                 .merge(rules.dig("weights", module_key.to_s) || {})
  end

  def descriptor
    { id: id, name: name, version: version, scope: platform_default? ? "platform" : account.public_id,
      thresholds: thresholds, armed_hard_stops: enabled_hard_stops }
  end

  # --------------------------------------------------------------------------
  # The default policy. Every number here is argued for in SOLUTION.md; the
  # short version is in the comments.
  # --------------------------------------------------------------------------
  DEFAULT_RULES = {
    # Independent noisy detectors, combined with noisy-OR:
    #   risk = 1 - Π(1 - contribution)
    # Chosen over a weighted sum because it matches the domain metaphor - each
    # layer is one imperfect voice raising doubt - and because it saturates
    # correctly. Two 0.35 signals give 0.58, not 0.70: a second dissenting voice
    # matters, but it cannot mechanically add its way past a threshold the way an
    # additive model can.
    "aggregation" => "noisy_or",

    "thresholds" => {
      # ACCEPT only when essentially nothing objected. 0.20 is set just above the
      # largest single advisory-only signal (a soft duplicate at 0.15) so that
      # one commercial flag alone cannot deny an otherwise clean lead - but that
      # flag plus any other doubt does tip into REVIEW.
      "accept_below" => 0.20,
      # REJECT once the combined doubt is substantial. Set at 0.60 rather than a
      # bare majority so that three moderate, partly-correlated objections
      # (~0.50) still get a human look: below this line the lead is a REVIEW,
      # because discarding a good lead costs real money while a second look
      # costs a minute. Two strong objections, or any 0.40+ signal joined by a
      # moderate one, clear it.
      "reject_at_or_above" => 0.60,
      # An ACCEPT is a claim we have to defend, so it requires that at least half
      # of the applicable enabled layers actually spoke.
      "coverage_floor" => 0.5
    },

    # Dispositive conditions. Each is a case where no amount of countervailing
    # evidence makes the lead purchasable, which is exactly the test for a hard
    # stop rather than a heavy weight.
    "hard_stops" => {
      # Legal exposure. A confirmed serial plaintiff with 14 filed complaints is
      # not a lead, it is a lawsuit with a phone number.
      "litigator_confirmed" => { "enabled" => true },
      # Off by default. "Suspected" is an unconfirmed pattern match, and the
      # brief is explicit that it is a judgement call - so it ships as a heavy
      # weighted signal that a risk-averse buyer can promote to a hard stop.
      "litigator_suspected" => { "enabled" => false },
      # If you cannot legally dial it, its value to a buyer of callable leads is
      # zero regardless of how genuine the person is.
      "dnc_listed" => { "enabled" => true },
      "callback_window_closed" => { "enabled" => true },
      # The entire product is provable consent. A cert that is missing, expired,
      # or does not match this lead's phone/email means the one thing we exist to
      # certify cannot be certified.
      "consent_unverifiable" => { "enabled" => true },
      # Commercial, not fraud: the buyer already owns this record and would pay
      # for it twice.
      "duplicate_hard" => { "enabled" => true },
      # Anura "bad" at 0.99 confidence with explicit rule ids is a determination,
      # not a suspicion - there is no consumer on the other end. Note that
      # "suspect" is deliberately NOT here; the brief says so, and so does
      # judgement.
      "bot_confirmed" => { "enabled" => true },
      # A reused voiceprint across four identities, or a synthetic voice, is
      # identity fraud on the only channel where we can prove it.
      "voice_fraud" => { "enabled" => true }
    },

    # Weighted signals: real doubt, but survivable in isolation.
    "weights" => {
      # First-party signal from the pixel itself - the only layer with no vendor
      # and no credit cost.
      "capture_behaviour" => {
        # 640ms to fill a four-field form is not a person typing.
        "instant_fill" => 0.20,
        "fast_fill" => 0.10,
        # Captured and left unchecked. Weighted, not a hard stop, because
        # TrustedForm is the authoritative consent record and it may still
        # evidence consent the checkbox missed.
        "consent_declined" => 0.30
      },
      "vpn_proxy" => {
        # The "VPN problem" the brief describes: browsed from a residential IP,
        # submitted through a commercial VPN. The mismatch is the tell, and it is
        # worse than either fact alone.
        "anonymizer_with_ip_mismatch" => 0.35,
        "anonymizer" => 0.20,
        "ip_mismatch" => 0.15,
        "elevated_risk" => 0.10
      },
      "anura" => {
        # A fraud-farm cluster is organised, repeat abuse rather than a one-off
        # oddity, so it carries more weight than a bare "suspect".
        "suspect_fraud_farm" => 0.30,
        "suspect" => 0.25
      },
      "trustedform" => {
        # Cert verified but the page carried no consent language.
        "consent_language_absent" => 0.25
      },
      "blacklist_alliance" => {
        # Heavy, because being wrong is a TCPA claim - but not dispositive while
        # it is only a pattern match. 0.30 alone lands in REVIEW, which is the
        # honest answer for "maybe a plaintiff".
        "suspected" => 0.30
      },
      "phone_validation" => {
        # Three providers, so this layer is a consensus in miniature.
        "majority_invalid" => 0.40,
        # 2 valid / 1 invalid - the providers cannot agree whether the number
        # exists. Exactly the case the brief flags: real disagreement, not a
        # verdict.
        "validity_disagreement" => 0.20,
        # They agree the number is real but not what kind of line it is. A
        # weaker signal than disagreeing about existence, and priced that way.
        "line_type_disagreement" => 0.12,
        # Reachable but disposable-friendly. TextNow numbers are cheap to churn.
        "all_voip" => 0.15
      },
      "email_validation" => {
        "consensus_undeliverable" => 0.35,
        "disposable" => 0.30,
        "providers_disagree" => 0.15,
        "elevated_fraud_score" => 0.15
      },
      "enrichment" => {
        # Neither source could resolve the identity at all. For a real consumer
        # with a real address this is unusual.
        "unresolved" => 0.20,
        # The enriched identity is not the person who filled the form.
        "identity_mismatch" => 0.20,
        # Two sources that disagree with each other cannot corroborate anything.
        "sources_disagree" => 0.20,
        # One source resolved, the other could not: thinner evidence, not bad
        # evidence.
        "single_source" => 0.10
      },
      "duplicate_detection" => {
        # Same phone, different email, hours apart. Priced at 0.15 - below the
        # ACCEPT threshold - on purpose: this is a BILLING question, not a fraud
        # question, and the brief asks for it to be surfaced for review rather
        # than auto-rejected. Alone it flags and accepts; combined with any other
        # doubt it tips the lead into REVIEW.
        "soft_duplicate" => 0.15
      },
      "voice" => {
        "low_confidence" => 0.15
      },

      # Fallback weights used when a buyer DISARMS a hard stop. Disarming must
      # not make a dispositive condition free, so each falls back to 0.65 -
      # above the REJECT threshold, so it still rejects on its own, but now
      # combinable with and overridable by other evidence. That is precisely the
      # semantic difference between "dispositive" and "very heavy".
      "disarmed_hard_stops" => {
        "litigator_confirmed" => 0.65,
        "dnc_listed" => 0.65,
        "callback_window_closed" => 0.65,
        "consent_unverifiable" => 0.65,
        "duplicate_hard" => 0.65,
        "bot_confirmed" => 0.65,
        "voice_fraud" => 0.65
      }
    },

    # What to do when a layer is enabled but could not answer. Consent-critical
    # layers fail CLOSED (cap at REVIEW - we will not vouch for consent we could
    # not check) and the rest fail OPEN (score without them, record the gap).
    # Neither ever fails to REJECT: a vendor outage is not the lead's fault, and
    # rejecting on it would destroy good leads the buyer has already paid for.
    "unavailable_handling" => {
      "default" => "fail_open",
      "consent_critical" => "fail_closed"
    }
  }.freeze

  private

  def rules_are_well_formed
    doc = rules
    return errors.add(:rules, "must be a JSON object") unless doc.is_a?(Hash)

    if (thresholds = doc["thresholds"])
      unless thresholds.is_a?(Hash)
        return errors.add(:rules, "thresholds must be an object")
      end

      accept = (thresholds["accept_below"] || DEFAULT_RULES.dig("thresholds", "accept_below")).to_f
      reject = (thresholds["reject_at_or_above"] || DEFAULT_RULES.dig("thresholds", "reject_at_or_above")).to_f
      errors.add(:rules, "accept_below must be less than reject_at_or_above") if accept >= reject
      unless (0.0..1.0).cover?(accept) && (0.0..1.0).cover?(reject)
        errors.add(:rules, "thresholds must be between 0 and 1")
      end
    end

    (doc["hard_stops"] || {}).each_key do |code|
      next if Engine::HardStops::CODES.include?(code)

      errors.add(:rules, "unknown hard stop #{code.inspect}")
    end

    (doc["weights"] || {}).each do |module_key, conditions|
      next errors.add(:rules, "weights.#{module_key} must be an object") unless conditions.is_a?(Hash)

      conditions.each do |condition, value|
        unless value.is_a?(Numeric) && (0.0..1.0).cover?(value.to_f)
          errors.add(:rules, "weights.#{module_key}.#{condition} must be between 0 and 1")
        end
      end
    end
  end
end
