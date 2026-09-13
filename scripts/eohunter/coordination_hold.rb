# frozen_string_literal: true

module EO::Engine
  # Opt-in coordination adapters; loading them never starts a listener.
  module Coordination
    # Safe-room hold/release policy over Lich's generic coordinated-operations
    # interface. Lich owns delivery, identity, replay and receipt mechanics;
    # this adapter alone decides when EOHunter may pause or resume.
    class HoldPilot
      # Fixed hold lifetime; expiry stops the pilot rather than resuming work.
      HOLD_SECONDS = 15.0
      OPERATIONS = {
        'hold'    => { required: [], optional: [] },
        'release' => { required: ['hold_id'], optional: [] }
      }.freeze

      # The caller owns the Session's connection lifecycle and must close this
      # adapter in ensure on the same thread. Eligibility is a local-only reader;
      # it must positively establish the connection and additional safety checks.
      #
      # @param engine [Engine] an empty engine, never an active hunting engine
      # @param session [#identity] native session identity, advanced on reconnect
      # @param peer [Hash] exact granted peer identity, including its run
      # @param control_token [String] dedicated credential, not a discovery/read token
      # @param safe_room [Integer] explicitly designated refuge
      # @param eligible [#call] returns true for a connected, locally eligible World
      # @param clock [#call] local monotonic seconds
      # @raise [ArgumentError] unavailable native interface or invalid adapter scope
      def initialize(engine:, session:, peer:, control_token:, safe_room:, eligible:,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        operations = native_operations
        schema = ::Lich::InternalAPI::Coordination::Schema
        unless engine.status[:behaviors].empty? && !engine.stopping? &&
               schema.identity?(session.identity) && schema.identity?(peer) &&
               schema.string?(control_token) && safe_room.is_a?(Integer) && safe_room.positive? &&
               eligible.respond_to?(:call)
          raise ArgumentError, 'hold adapter requires an empty engine and explicit safe-room grant'
        end

        @engine, @session, @eligible, @clock = engine, session, eligible, clock
        @identity, @safe_room = schema.immutable(session.identity), safe_room
        @thread = Thread.current
        @hold_owner = Object.new.freeze
        @grant = operations::Grant.new(session: session, peer: peer, control_token: control_token,
                                       operations: OPERATIONS, enabled: true, clock: clock)
        @revocation_mutex = Mutex.new
        @revoked = false
        @closed = false
        @started = false
        @pending = nil
        @applying = nil
        @active = nil
        @tick = 0
        engine.on_tick { |world| owner_tick(world) }
        engine.on_tick_completed { |_world, tick, state| confirm(tick, state) }
      end

      # Start the native, explicitly granted endpoint. No discovery write.
      # @return [Hash] token-free descriptor for this exact control grant
      def start
        assert_owner!
        raise ArgumentError, 'adapter closed' if @closed
        raise 'native operation grant did not start' unless @grant.start

        @started = true
        @grant.descriptor
      end

      # Close admission from any thread. The next owner tick performs EOHunter
      # cleanup and reports it through the native receipt.
      # @return [nil]
      def revoke
        @grant.revoke('adapter_revoked')
        @revocation_mutex.synchronize { @revoked = true }
        nil
      end

      # Explicit owner-thread teardown; the engine retains policy ownership.
      # @return [nil]
      def close
        assert_owner!
        fail_closed('adapter_closed') unless @closed
        @grant.close
        nil
      end

      private

      def native_operations
        return ::Lich::InternalAPI::Coordination::Operations if defined?(::Lich::InternalAPI::Coordination::Operations::Grant)

        raise ArgumentError, 'load Lich coordinated operations first'
      end

      # The start callback only rechecks local policy and applies work already
      # admitted on a completed owner tick. It never reads the transport.
      def owner_tick(world)
        assert_owner!
        return unless @started && !@closed

        safe = begin
          safe?(world)
        rescue StandardError
          fail_closed('owner_check_failed')
          return
        end
        unless safe
          fail_closed('authority_or_safety_lost')
          return
        end
        if revoked? || @engine.stopping?
          fail_closed('authority_or_safety_lost')
        elsif lease_expired?
          fail_closed('hold_lease_expired')
        elsif @pending
          apply(@pending)
        end
      end

      def safe?(world)
        @session.identity == @identity && world.room.id == @safe_room &&
          world.room.live_creatures.empty? && world.me.dead? == false &&
          world.me.in_rt? == false && world.me.in_cast_rt? == false && @eligible.call(world) == true
      end

      def apply(request)
        @pending = nil
        @applying = request.dup
        if request[:operation] == 'hold'
          if @active
            @applying[:denied_reason] = 'already_held'
          else
            @engine.pause!(owner: @hold_owner)
            @applying[:lease_deadline] = @clock.call + HOLD_SECONDS
          end
        elsif !@active || @active[:request_id] != request[:arguments]['hold_id']
          @applying[:denied_reason] = 'hold_mismatch'
        else
          @engine.resume!(owner: @hold_owner)
        end
      end

      # Completed callbacks first settle any action applied this turn, then take
      # at most one new native request for the following owner turn.
      def confirm(tick, state)
        assert_owner!
        @tick = tick
        return unless @started && !@closed

        if lease_expired?
          fail_closed('hold_lease_expired')
          return
        end
        settle_applied(tick, state) if @applying
        return if @closed || @pending || @applying

        @pending = @grant.next_request(owner_tick: tick)
      end

      def settle_applied(tick, state)
        request = @applying
        @applying = nil
        if request[:denied_reason]
          @grant.settle(request_id: request[:request_id], owner_tick: tick, outcome: :failed,
                        reason: request[:denied_reason], cleanup: :complete)
        elsif request[:operation] == 'hold'
          @grant.settle(request_id: request[:request_id], owner_tick: tick, outcome: :succeeded,
                        result: { engine_state: state[:state].to_s }, cleanup: :pending)
          @active = { request_id: request[:request_id], lease_deadline: request[:lease_deadline] }
        else
          @grant.settle(request_id: request[:request_id], owner_tick: tick, outcome: :succeeded,
                        result: { engine_state: state[:state].to_s }, cleanup: :complete)
          @grant.finish_cleanup(request_id: @active[:request_id], owner_tick: tick)
          @active = nil
        end
      end

      def lease_expired?
        held = @active || (@applying if @applying && @applying[:operation] == 'hold')
        held && @clock.call >= held[:lease_deadline]
      end

      def revoked?
        @revocation_mutex.synchronize { @revoked }
      end

      # This method runs only on the owner thread. It closes admission, stops
      # local work, releases only this adapter's hold, and truthfully resolves
      # every request already taken from the native mailbox.
      def fail_closed(reason)
        @grant.revoke(reason)
        @engine.stop!(reason.to_sym)
        @engine.resume!(owner: @hold_owner)
        settle_interrupted(@pending, reason, performed: false)
        @pending = nil
        settle_interrupted(@applying, reason, performed: @applying && !@applying[:denied_reason])
        @applying = nil
        finish_active_cleanup
        @active = nil
        @closed = true
      end

      def settle_interrupted(request, reason, performed:)
        return unless request

        @grant.settle(request_id: request[:request_id], owner_tick: [@tick, request[:owner_tick]].compact.max,
                      outcome: performed ? :unknown : :failed, reason: reason, cleanup: :complete)
      end

      def finish_active_cleanup
        return unless @active

        @grant.finish_cleanup(request_id: @active[:request_id], owner_tick: [@tick, 1].max)
      end

      def assert_owner!
        raise ThreadError, 'hold adapter must run on its engine owner thread' unless Thread.current == @thread
      end
    end
  end
end
