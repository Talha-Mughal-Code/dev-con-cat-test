module Credits
  # Raised when an account cannot afford a charge. Carries the shortfall so the
  # caller can decide between running a reduced set of layers and halting.
  class InsufficientCredits < StandardError
    attr_reader :account, :requested, :available

    def initialize(account:, requested:, available:)
      @account = account
      @requested = requested
      @available = available
      super("#{account.public_id} has #{available} credits but #{requested} were requested")
    end

    def shortfall = requested - available
  end
end
