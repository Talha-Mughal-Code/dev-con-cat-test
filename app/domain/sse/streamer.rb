module Sse
  # Server-sent events, tailing the activity_events table by primary key.
  #
  # WHY SSE RATHER THAN ACTIONCABLE - the reasoning in full, since the brief
  # asks for it to be justified:
  #
  #   * The stream is one-way. The pixel sends nothing back over it, so a
  #     bidirectional WebSocket buys nothing and costs a protocol upgrade.
  #   * The consumer is a third-party page on someone else's domain. SSE is
  #     cross-origin with ordinary CORS headers; ActionCable needs
  #     allowed_request_origins configured per buyer.
  #   * Reconnection is free and, more importantly, LOSSLESS. The browser
  #     resends Last-Event-ID automatically, and because activity_events has a
  #     monotonic primary key, resuming is `WHERE id > cursor` - no gaps, no
  #     duplicates, no replay buffer to size.
  #   * The layer jobs run in a different process from the web server. With no
  #     Redis available, ActionCable's async adapter cannot cross that boundary
  #     at all, so it would need a pubsub dependency purely to reach the browser.
  #     Both processes already share the database, so tailing a table needs
  #     nothing new.
  #
  # WHAT THIS TRADES AWAY: a thread per open connection. Fine for a demo and for
  # a modest production load, wrong at tens of thousands of concurrent viewers -
  # at which point the answer is pubsub behind an evented server, not a bigger
  # thread pool. The 250ms poll also means events are up to 250ms late, which is
  # imperceptible next to the vendor latency it is reporting on.
  class Streamer
    POLL_INTERVAL = 0.25.seconds
    HEARTBEAT_INTERVAL = 15.seconds
    # Connections are recycled rather than held forever: proxies time them out
    # anyway, and the browser reconnects with Last-Event-ID at no cost.
    MAX_DURATION = 2.minutes

    TERMINAL_KINDS = %w[final_verdict run_halted run_errored].freeze

    def initialize(stream:, lead_id:, account:, cursor: nil)
      @stream = stream
      @lead_id = lead_id
      @account = account
      @cursor = cursor.to_i
      @started_at = Time.current
      @last_heartbeat = Time.current
    end

    def call
      write_comment("stream open")

      loop do
        break if expired?

        events = fetch_events
        events.each { |event| write_event(event) }

        return if events.any? { |event| TERMINAL_KINDS.include?(event.kind) }

        heartbeat_if_due
        sleep POLL_INTERVAL
      end

      # Tells the browser this close was orderly, so it reconnects rather than
      # treating it as an error.
      write_comment("stream idle - reconnect with Last-Event-ID #{@cursor}")
    rescue ActionController::Live::ClientDisconnected, IOError, Errno::EPIPE
      # The visitor navigated away. Entirely normal, not worth logging as an
      # error.
      nil
    end

    private

    attr_reader :stream, :lead_id, :account

    # A connection per viewer holds a database connection while polling, so it
    # is checked out and returned around each poll rather than held for the
    # life of the stream. Without this a handful of open panels would exhaust
    # the pool.
    def fetch_events
      ActiveRecord::Base.connection_pool.with_connection do
        TenantScope.for_account(account) do
          ActivityEvent.where(lead_id: lead_id).after_cursor(@cursor).chronological.limit(50).to_a
        end
      end
    end

    def write_event(event)
      payload = event.to_stream_event
      @cursor = event.id
      stream.write("id: #{event.id}\n")
      stream.write("event: #{payload[:type]}\n")
      stream.write("data: #{JSON.generate(payload)}\n\n")
    end

    def heartbeat_if_due
      return if Time.current - @last_heartbeat < HEARTBEAT_INTERVAL

      @last_heartbeat = Time.current
      write_comment("heartbeat")
    end

    # A comment line keeps the connection alive through proxies without the
    # client seeing a spurious event.
    def write_comment(text)
      stream.write(": #{text}\n\n")
    end

    def expired? = Time.current - @started_at > MAX_DURATION
  end
end
