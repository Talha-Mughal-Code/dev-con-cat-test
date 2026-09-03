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
    MAX_ATTEMPTS = 6
    BASE_DELAY = 0.02

    class << self
      def on_contention(attempts: MAX_ATTEMPTS)
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
      end

      def contention?(error)
        error.message.to_s.match?(CONTENTION)
      end
    end
  end
end
