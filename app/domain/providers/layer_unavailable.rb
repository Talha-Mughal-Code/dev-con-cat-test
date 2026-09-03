module Providers
  # Raised when a layer is enabled but could not produce an answer. The
  # pipeline turns this into state = errored, which then drives the policy's
  # fail-open / fail-closed handling. Modelled as an exception rather than a
  # sentinel value so that a vendor client which times out, 500s, or returns
  # garbage all converge on the same handling.
  class LayerUnavailable < StandardError
    attr_reader :module_key

    def initialize(module_key, message = nil)
      @module_key = module_key
      super(message || "provider for #{module_key} is unavailable")
    end
  end
end
