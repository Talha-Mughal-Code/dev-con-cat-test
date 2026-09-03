module Database
  # Retries a write that lost a race for SQLite's single writer.
  #
  # WHY THIS IS NEEDED. Layer jobs run in parallel by design - vendor calls are
  # I/O-bound and serialising them would triple the latency the landing page
  # waits on. But SQLite permits one writer at a time, and busy_timeout does not
  # help in the case that actually bites: a DEFERRED transaction (Rails'
  # default) takes a read lock, then tries to upgrade to a write after another
  # connection has already written. SQLite refuses immediately rather than
  # waiting, because waiting would break the reader's snapshot.
  #
  # So contention has to be handled by retrying the transaction rather than by
  # waiting inside it. Exponential backoff with jitter, because several jobs
  # finishing together would otherwise retry in lockstep and collide again.
  #
  # WHAT THIS IS NOT. It is not a substitute for correctness: every retried
  # block is idempotent (credit charges are keyed, layer rows are claimed
  # conditionally), so re-running one is safe. And if contention outlasts the
  # retries, the error is re-raised so the job's own retry can take over - a
  # transient lock must never be recorded as a layer that permanently failed,
  # because a fail-closed layer would then downgrade an otherwise good lead.
  #
  # On PostgreSQL, with real MVCC and row-level locking, none of this is
  # necessary - which is the honest trade-off for choosing a zero-setup database.
  module Retry
    CONTENTION = /database is locked|database table is locked|SQLITE_BUSY|busy/i
    # A BACKSTOP, not the primary mechanism. BEGIN IMMEDIATE plus busy_timeout
    # means SQLite now queues for the write lock instead of refusing to upgrade
    # one, so reaching this code at all means a transaction waited out the full
    # busy_timeout - a real overload rather than a momentary collision. Retrying
    # such a case many times with exponential backoff only turns a fast failure
    # into a slow one, so the budget is deliberately small.
    MAX_ATTEMPTS = 3
    BASE_DELAY = 0.05

    class << self
      def on_contention(attempts: MAX_ATTEMPTS)
        # RE-ENTRANT ON PURPOSE. These blocks nest - a layer's row and its
        # activity event share a transaction, and the recorder wraps its own
        # write too - and nesting retries is worse than useless. The budgets
        # multiply (three attempts inside three attempts, each willing to wait
        # out a 5s busy_timeout, is over a minute of waiting), and retrying an
        # inner block is pointless anyway because the enclosing transaction is
        # already doomed. Only the outermost block retries.
        return yield if Thread.current[:database_retry_depth].to_i.positive?

        Thread.current[:database_retry_depth] = 1
        tries = 0

        begin
          yield
        rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished => e
          raise unless contention?(e)

          tries += 1
          raise if tries >= attempts

          sleep(BASE_DELAY * (2**(tries - 1)) * (0.5 + rand))
          retry
        end
      ensure
        Thread.current[:database_retry_depth] = nil
      end

      def contention?(error)
        error.message.to_s.match?(CONTENTION)
      end
    end
  end
end
