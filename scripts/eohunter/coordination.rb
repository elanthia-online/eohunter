# frozen_string_literal: true

module EO::Engine
  # Opt-in, read-only projection of existing group policy at an owner tick.
  # No endpoint, observer, game command, or movement barrier is installed here.
  module Coordination
    # Copies Group.report and the existing movement predicate for a core session.
    # World currently samples native readers independently. Generation fences
    # reject known mixed captures, but cannot make those readers atomic.
    class Adapter
      # Why this projection cannot authorize a coordinated movement decision.
      LIMITATIONS = ['Group.report and movement readiness sample World independently; no shared native writer contract.'].freeze

      # @return [Hash, nil] last immutable projection accepted by the publisher
      attr_reader :last_projection
      # @return [Symbol, nil] local failure diagnostic, never a game exception
      attr_reader :last_error

      # Readers run only on the owning engine's completed-tick callback. They
      # must copy existing local state; they must not make network/game queries.
      # report_reader reuses Group.report with the owner's existing settings.
      # movement_reader reuses Group::Leader#movement_ready? when available.
      #
      # @param publisher [#identity, #publish] opt-in Lich coordination session
      # @param report_reader [#call] returns the existing Group::Report for World
      # @param movement_reader [#call, nil] existing local movement predicate
      # @param source_reader [#call, nil] native generation/version/age metadata
      def initialize(publisher:, report_reader:, movement_reader: nil, source_reader: nil)
        @publisher = publisher
        @report_reader = report_reader
        @movement_reader = movement_reader
        @source_reader = source_reader
        @sequence = 0
        @last_tick = 0
      end

      # Explicit programmatic pilot wiring; loading the module is inert.
      # One adapter belongs to one engine run and one publishing session.
      #
      # @param engine [Engine] the existing local owner
      # @return [Adapter] self
      def attach(engine)
        raise ArgumentError, 'adapter already attached' if @engine

        @engine = engine
        engine.on_tick_completed do |world, tick, owner|
          capture(world, tick, owner)
        end
        self
      end

      private

      def capture(world, tick, owner)
        return if tick <= @last_tick

        @last_tick = tick
        @last_error = nil
        identity = copy(@publisher.identity)
        owner_before = copy(owner)
        before = metadata(world)
        room_before = copy(world.room.id)
        report = @report_reader.call(world)
        movement = boolean(@movement_reader&.call(world))
        room_after = copy(world.room.id)
        after = metadata(world)
        unless identity == @publisher.identity && binding(before) == binding(after) &&
               room_before == room_after && report&.room == room_after && owner_before == @engine.status
          @last_error = :mixed_capture
          return
        end

        projection = copy(
          identity: identity, sequence: @sequence += 1, owner_tick: tick,
          connected: boolean(after[:connected]),
          room: { id: room_after, epoch: after[:room_epoch] },
          readiness: {
            ready: nil, coherence: 'unknown', limitations: LIMITATIONS,
            movement_ready: movement, roundtime: boolean(report.rt), looting: boolean(report.looting),
            owner: { state: owner_before[:state].to_s, behavior: owner_before[:behavior] }
          },
          sources: { room: after[:room], readiness: after[:readiness] }
        )
        if @publisher.publish(**projection)
          @last_projection = projection
        else
          @last_error = :publisher_rejected
        end
      rescue StandardError
        # The optional read-only pilot must not stop an otherwise healthy hunt.
        # No stale publication is refreshed after a reader/publisher failure.
        @last_error = :capture_failed
      end

      def metadata(world)
        value = @source_reader&.call(world)
        return {}.freeze if value.nil?
        raise ArgumentError, 'source metadata must be a hash' unless value.is_a?(Hash)

        copy(value)
      end

      def binding(metadata)
        metadata.values_at(:connection_generation, :room_epoch)
      end

      def boolean(value)
        value if value == true || value == false
      end

      def copy(value)
        case value
        when Hash
          value.to_h { |key, item| [copy(key), copy(item)] }.freeze
        when Array
          value.map { |item| copy(item) }.freeze
        when String
          value.dup.freeze
        when Symbol, Numeric, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError, 'projection must contain only plain values'
        end
      end
    end
  end
end
