module Engine
  module Evaluators
    # An evaluator TRANSLATES one vendor's response into our vocabulary. It does
    # not judge. It answers "what did this vendor observe?" and leaves "how much
    # does that matter?" to Consensus, which is the only place thresholds and
    # weights live.
    class Base
      # module_key must match a DetectionModule key and a key in the policy's
      # weights document.
      def self.module_key
        raise NotImplementedError
      end

      # Some layers do not apply to some leads - the brief's example is a voice
      # check on a lead with no voice sample. An evaluator says so here, and the
      # pipeline records state = not_applicable rather than inventing a pass.
      def applicable?(_payload, _context) = true

      def call(_payload, _context)
        raise NotImplementedError
      end

      private

      def module_key = self.class.module_key

      def finding(hard_stop_code: nil, weight_key: nil, detail:, advisory: false)
        Finding.new(module_key: module_key, hard_stop_code: hard_stop_code,
                    weight_key: weight_key, detail: detail, advisory: advisory)
      end

      def assessment(findings: [], summary:, breakdown: {})
        Assessment.new(module_key: module_key, findings: Array(findings),
                       summary: summary, breakdown: breakdown)
      end

      def truthy?(value) = value == true

      def falsey?(value) = value == false
    end
  end
end
