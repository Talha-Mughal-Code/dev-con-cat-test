module Engine
  # The vocabulary of dispositive conditions.
  #
  # Each code names a case where no amount of countervailing evidence makes the
  # lead purchasable - which is exactly the test for a hard stop rather than a
  # heavy weight. That test is why this list is short and why "Anura says
  # suspect" is not on it.
  #
  # This vocabulary is CODE, deliberately, while which codes are armed is DATA
  # (see ConsensusPolicy). Each entry encodes a legal or economic claim that has
  # to be reviewable in a diff and testable in isolation; a settings screen
  # should be able to disarm one, not invent one.
  module HardStops
    Definition = Struct.new(:code, :module_key, :headline, :rationale, :fallback_weight_key,
                            keyword_init: true)

    ALL = [
      Definition.new(
        code: "litigator_confirmed",
        module_key: "blacklist_alliance",
        headline: "Confirmed serial TCPA litigator",
        rationale: "A phone number tied to filed TCPA complaints is not a lead, it is a " \
                   "lawsuit with a dial tone. No other signal offsets that exposure.",
        fallback_weight_key: "confirmed"
      ),
      Definition.new(
        code: "litigator_suspected",
        module_key: "blacklist_alliance",
        headline: "Suspected professional plaintiff",
        rationale: "An unconfirmed pattern match. Ships DISARMED because the brief is " \
                   "explicit that this is a judgement call, so by default it is a heavy " \
                   "weighted signal a risk-averse buyer can promote to dispositive.",
        fallback_weight_key: "suspected"
      ),
      Definition.new(
        code: "dnc_listed",
        module_key: "dnc",
        headline: "Number is on a Do-Not-Call list",
        rationale: "If the buyer cannot legally dial it, the lead's value to a buyer of " \
                   "callable leads is zero however genuine the person is.",
        fallback_weight_key: "listed"
      ),
      Definition.new(
        code: "callback_window_closed",
        module_key: "dnc",
        headline: "Callback window is closed",
        rationale: "Same reasoning as a DNC listing: not dialable right now means not " \
                   "purchasable right now.",
        fallback_weight_key: "window_closed"
      ),
      Definition.new(
        code: "consent_unverifiable",
        module_key: "trustedform",
        headline: "Consent cannot be proven",
        rationale: "The entire product is provable consent. A certificate that is missing, " \
                   "expired, or does not match this lead's phone, email or landing page " \
                   "means the one thing we exist to certify cannot be certified.",
        fallback_weight_key: "unverifiable"
      ),
      Definition.new(
        code: "duplicate_hard",
        module_key: "duplicate_detection",
        headline: "Already in this account's CRM",
        rationale: "Commercial rather than fraud: the buyer already owns this record and " \
                   "would pay for it a second time. Matching on phone AND email within the " \
                   "same account leaves little room for coincidence.",
        fallback_weight_key: "hard_duplicate"
      ),
      Definition.new(
        code: "bot_confirmed",
        module_key: "anura",
        headline: "Confirmed automated submission",
        rationale: "Anura 'bad' arrives with explicit rule ids at high confidence - a " \
                   "determination, not a suspicion. There is no consumer on the other end " \
                   "to consent to anything.",
        fallback_weight_key: "confirmed_bad"
      ),
      Definition.new(
        code: "voice_fraud",
        module_key: "voice",
        headline: "Voice-actor or synthetic-voice fraud",
        rationale: "One voiceprint submitted under several identities, or a synthetic voice, " \
                   "is identity fraud evidenced on the one channel where it is provable.",
        fallback_weight_key: "fraud"
      )
    ].freeze

    CODES = ALL.map(&:code).freeze

    BY_CODE = ALL.index_by(&:code).freeze

    def self.find(code)
      BY_CODE.fetch(code.to_s) do
        raise ArgumentError, "unknown hard stop #{code.inspect}"
      end
    end

    def self.for_module(module_key)
      ALL.select { |definition| definition.module_key == module_key.to_s }
    end
  end
end
