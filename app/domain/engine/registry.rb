module Engine
  # Maps a module key to its evaluator. The single place the engine learns that
  # a new layer exists.
  module Registry
    EVALUATORS = {
      "capture_behaviour"  => Evaluators::CaptureBehaviour,
      "vpn_proxy"          => Evaluators::VpnProxy,
      "anura"              => Evaluators::Anura,
      "trustedform"        => Evaluators::Trustedform,
      "blacklist_alliance" => Evaluators::BlacklistAlliance,
      "dnc"                => Evaluators::Dnc,
      "phone_validation"   => Evaluators::PhoneValidation,
      "email_validation"   => Evaluators::EmailValidation,
      "enrichment"         => Evaluators::Enrichment,
      "duplicate_detection" => Evaluators::DuplicateDetection,
      "voice"              => Evaluators::Voice
    }.freeze

    MODULE_KEYS = EVALUATORS.keys.freeze

    def self.for(module_key)
      klass = EVALUATORS[module_key.to_s]
      raise ArgumentError, "no evaluator for module #{module_key.inspect}" unless klass

      klass.new
    end

    def self.known?(module_key) = EVALUATORS.key?(module_key.to_s)
  end
end
