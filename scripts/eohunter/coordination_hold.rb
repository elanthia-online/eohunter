# frozen_string_literal: true

module EO::Engine
  # Opt-in coordination adapters; loading them never starts a listener.
  module Coordination
    # Explicit, safe-room-only hold/release experiment. Native transport workers
    # reserve requests; the existing empty engine applies them on its owner tick.
    # Not a hunting controller, and not loaded with a listener by default.
    class HoldPilot
      # Maximum reservations retained for the entire grant (no replay eviction).
      CAPACITY = 32
      # Receiver-local seconds allowed between ticket issuance and application.
      TICKET_SECONDS = 5.0
      # Fixed hold lifetime; expiry stops the pilot rather than resuming it.
      HOLD_SECONDS = 15.0
      # Wire contract separate from the read-only coordination protocol.
      VERSION = 1

      # The caller owns the Session's connection lifecycle and must close this
      # pilot in ensure on the same thread. Eligibility is a local-only reader;
      # it must positively establish the connection and additional safety checks.
      #
      # @param engine [Engine] an empty engine, never an active hunting engine
      # @param session [#identity] native session identity, advanced on reconnect
      # @param peer [Hash] exact granted peer identity, including its run
      # @param control_token [String] dedicated credential, not a discovery/read token
      # @param safe_room [Integer] explicitly designated refuge
      # @param eligible [#call] returns true for a connected, locally eligible World
      # @param clock [#call] local monotonic seconds
      # @raise [ArgumentError] unavailable native protocol or invalid pilot scope
      def initialize(engine:, session:, peer:, control_token:, safe_room:, eligible:,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        unless defined?(::Lich::InternalAPI::Coordination::Schema)
          raise ArgumentError, 'load the native coordination prototype first'
        end
        @schema = ::Lich::InternalAPI::Coordination::Schema
        unless engine.status[:behaviors].empty? && !engine.stopping? &&
               @schema.identity?(session.identity) && @schema.identity?(peer) &&
               @schema.string?(control_token) && safe_room.is_a?(Integer) && safe_room.positive? &&
               eligible.respond_to?(:call)
          raise ArgumentError, 'hold pilot requires an empty engine and explicit safe-room grant'
        end

        @engine, @session, @eligible, @clock = engine, session, eligible, clock
        @identity, @peer = copy(session.identity), copy(peer)
        @token, @safe_room = control_token.dup.freeze, safe_room
        @thread = Thread.current
        @hold_owner = Object.new.freeze
        @mutex = Mutex.new
        @entries = {}
        @closed = false
        @started = false
        @active = nil
        @tick = 0
        engine.on_tick { |world| owner_tick(world) }
        engine.on_tick_completed { |_world, tick, state| confirm(tick, state) }
      end

      # Start a separate explicitly granted endpoint. No native discovery write.
      # @return [Hash] token-free descriptor for this control grant
      def start
        assert_owner!
        raise ArgumentError, 'pilot closed' if @closed

        @server ||= ::Lich::InternalAPI::ActiveSessions::Server.new(
          host: '127.0.0.1', port: 0, registry: nil, auth_token: @token,
          request_handler: method(:route), max_frame_bytes: 16_384, max_clients: 4, timeout: 0.25
        )
        @server.start
        @started = true
        copy(protocol_version: VERSION, host: @server.host, port: @server.port,
             identity: @identity, peer: @peer)
      end

      # Local revocation is thread-safe. It does not claim the owner has stopped.
      # No further admissions; the next owner tick performs cleanup.
      # @return [nil]
      def revoke
        @mutex.synchronize { @closed = true }
        nil
      end

      # Explicit owner-thread teardown; native Script still owns script lifetime.
      # Network shutdown happens outside the receipt lock.
      # @return [nil]
      def close
        assert_owner!
        @mutex.synchronize { fail_closed('pilot_closed') }
        @server&.stop
        nil
      end

      private

      def route(request)
        @mutex.synchronize do
          return failure('invalid_request') unless @schema.exact_keys?(request, %i[command auth payload])

          payload = request[:payload]
          return failure('invalid_request') unless payload.is_a?(Hash)
          return failure('identity_mismatch') unless payload[:identity] == @identity && payload[:peer] == @peer
          return failure('protocol_mismatch') unless payload[:protocol_version] == VERSION

          required = %i[protocol_version identity peer request_id]
          required += %i[operation hold_id] if request[:command] == 'ticket'
          required += [:ticket] if request[:command] == 'submit'
          return failure('invalid_request') unless @schema.exact_keys?(payload, required) &&
                                                   @schema.string?(payload[:request_id])
          return failure('unsupported_command') unless %w[ticket submit result].include?(request[:command])

          id = payload[:request_id]
          entry = @entries[id]
          return entry ? receipt(entry) : failure('unknown_request') if request[:command] == 'result'
          return failure('grant_closed') if @closed

          if request[:command] == 'ticket'
            reserve(id, payload, entry)
          else
            submit(entry, payload[:ticket])
          end
        end
      end

      def reserve(id, payload, entry)
        operation, hold_id = payload.values_at(:operation, :hold_id)
        unless (operation == 'hold' && hold_id.nil?) || (operation == 'release' && @schema.string?(hold_id))
          return failure('unsupported_operation')
        end
        if entry
          return failure('request_conflict') unless entry[:operation] == operation && entry[:hold_id] == hold_id

          return ticket(entry)
        end
        return failure('grant_capacity') if @entries.size >= CAPACITY

        entry = { request_id: id.dup.freeze, operation: operation.dup.freeze, hold_id: hold_id&.dup&.freeze,
                  ticket: SecureRandom.hex(16), deadline: @clock.call + TICKET_SECONDS,
                  state: 'reserved', cleanup: 'not_required', owner_tick: nil, engine_state: nil }
        @entries[entry[:request_id]] = entry
        ticket(entry)
      end

      def ticket(entry)
        expire(entry)
        { ok: true, payload: copy(request_id: entry[:request_id], ticket: entry[:ticket],
                                  remaining_seconds: [entry[:deadline] - @clock.call, 0.0].max,
                                  state: entry[:state]) }
      end

      def submit(entry, token)
        return failure('invalid_ticket') unless entry && @schema.string?(token) && token == entry[:ticket]

        expire(entry)
        entry[:state] = 'pending' if entry[:state] == 'reserved'
        receipt(entry)
      end

      def expire(entry)
        return unless %w[reserved pending].include?(entry[:state]) && @clock.call >= entry[:deadline]

        entry[:state], entry[:reason] = 'expired', 'ticket_expired'
      end

      def receipt(entry)
        expire(entry)
        value = entry.reject { |key, _| %i[ticket deadline lease_deadline observed_at].include?(key) }
        value[:owner_age] = entry[:observed_at] && [@clock.call - entry[:observed_at], 0.0].max
        { ok: true, payload: copy(value) }
      end

      def owner_tick(world)
        assert_owner!
        return unless @started

        advance(world)
      end

      def advance(world)
        safe = @session.identity == @identity && world.room.id == @safe_room &&
               world.room.live_creatures.empty? && world.me.dead? == false &&
               world.me.in_rt? == false && world.me.in_cast_rt? == false && @eligible.call(world) == true
        @mutex.synchronize do
          if @closed || @engine.stopping? || !safe
            fail_closed('authority_or_safety_lost')
          elsif @active && @clock.call >= @active[:lease_deadline]
            fail_closed('hold_lease_expired')
          else
            @entries.each_value { |entry| expire(entry) }
            entry = @entries.values.find { |item| item[:state] == 'pending' }
            apply(entry) if entry
          end
        end
      rescue StandardError
        @mutex.synchronize { fail_closed('owner_check_failed') }
      end

      def apply(entry)
        if entry[:operation] == 'hold'
          return deny(entry, 'already_held') if @active

          @engine.pause!(owner: @hold_owner)
          @active = entry
          entry[:lease_deadline] = @clock.call + HOLD_SECONDS
          entry[:cleanup] = 'pending'
        else
          return deny(entry, 'hold_mismatch') unless @active && @active[:request_id] == entry[:hold_id]
          # Do not collapse a hold and release into one unobserved owner turn.
          return deny(entry, 'hold_not_confirmed') unless @active[:state] == 'applied'

          @engine.resume!(owner: @hold_owner)
        end
        entry[:state] = 'applying'
      end

      def confirm(tick, state)
        assert_owner!
        @mutex.synchronize do
          @tick = tick
          return if @closed
          if @active && @clock.call >= @active[:lease_deadline]
            fail_closed('hold_lease_expired')
            return
          end
          @entries.each_value do |entry|
            next unless entry[:state] == 'applying'

            entry[:state], entry[:owner_tick], entry[:engine_state] = 'applied', tick, state[:state].to_s
            entry[:observed_at] = @clock.call
            next unless entry[:operation] == 'release'

            @active[:cleanup] = 'complete'
            @active[:released_by] = entry[:request_id]
            @active[:cleanup_owner_tick] = tick
            @active = nil
          end
        end
      end

      def fail_closed(reason)
        @closed = true
        @engine.stop!(reason.to_sym)
        @engine.resume!(owner: @hold_owner)
        @entries.each_value do |entry|
          if %w[reserved pending applying].include?(entry[:state])
            entry[:state], entry[:reason] = 'failed', reason
          end
          if entry[:cleanup] == 'pending'
            entry[:cleanup] = 'complete'
            entry[:cleanup_reason] = reason
          end
        end
        @active = nil
      end

      def deny(entry, reason)
        entry[:state], entry[:reason] = 'failed', reason
      end

      def assert_owner!
        raise ThreadError, 'hold pilot must run on its engine owner thread' unless Thread.current == @thread
      end

      def copy(value) = @schema.immutable(value)
      def failure(reason) = { ok: false, error: reason }
    end
  end
end
