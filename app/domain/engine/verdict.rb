module Engine
  # The engine's output. A verdict is never just a word: it always carries the
  # reasons that produced it, the arithmetic behind them, and how complete the
  # check was - because a buyer who cannot explain why they rejected a lead
  # cannot defend the rejection, and neither can we.
  Verdict = Struct.new(
    :value,              # "accept" | "review" | "reject"
    :code,               # machine-readable primary reason
    :risk,               # 0.0-1.0, forced to 1.0 when a hard stop fires
    :weighted_risk,      # what the score alone said, retained even when a hard stop overrode it
    :confidence,
    :reasons,            # ordered, most significant first
    :layer_contributions,
    :hard_stops,
    :advisories,
    :coverage,
    keyword_init: true
  ) do
    def accepted? = value == "accept"
    def rejected? = value == "reject"
    def review?   = value == "review"

    def hard_stopped? = hard_stops.present?

    def primary_reason = reasons.first&.fetch(:message, nil)

    def to_h_for_storage
      {
        "value" => value,
        "code" => code,
        "risk" => risk.round(4),
        "weighted_risk" => weighted_risk.round(4),
        "confidence" => confidence.round(4),
        "reasons" => reasons.map { |r| r.transform_keys(&:to_s) },
        "coverage" => coverage.transform_keys(&:to_s)
      }
    end
  end
end
