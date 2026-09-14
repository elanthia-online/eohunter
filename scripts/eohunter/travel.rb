# frozen_string_literal: true

# ============================================================================
# travel (bigshot's goto and go2, supervised a tick at a time)
# ============================================================================

#
# bigshot's goto runs the go2 script up to five times and blocks
# until it ends; go2 unhides first and skips the trip when already
# there. libeo's EO.go2 is that call, and Rest and Wander used it as a
# blocking step: pause and stop could not land during a trip, and an
# escape room or a death mid-trip went unseen until go2 gave up. The
# engine's Trip starts the same go2 script and watches it one tick at a
# time: arrival by room, a script that ended short as one failed attempt,
# five attempts as could_not_reach, and cancel! for the engine's stop.
# Survival outranks whoever holds the trip, so an escape room or a death
# mid-trip is handled between ticks. A trip belongs to the behavior that
# holds control: when the engine hands control to someone else, the
# holder's trip is suspended (go2 killed, the trip kept) and resumes,
# not counted as an attempt, when the holder gets control back; only
# one trip runs go2 at a time. Rules and bigshot line references in
# hunting-engine-plan.md, "Travel".
#
module EO::Engine
  # bigshot's goto and go2 as a supervised trip: `Trip` ticks one go2 run
  # at a time, and the module functions drive a behavior's trip, cancel or
  # suspend it, and keep one go2 running across all holders.
  #
  # @bigshot goto
  # @bigshot go2
  module Travel
    # One trip to a place through the go2 script, watched a tick at a
    # time: arrival by room, a script that ended short as one failed
    # attempt, the attempts spent as could_not_reach, cancel! for the
    # engine's stop and suspend! when the holder loses control.
    class Trip
      # Attempts before could_not_reach (bigshot goto 6686).
      ATTEMPTS = 5 # bigshot goto 6686
      # Seconds to wait before starting go2 again after it ended short.
      RETRY_DELAY = 1.0
      # The Lich script that does the walking.
      SCRIPT = 'go2'

      # The place go2 was given (a room id, "u" uid or map tag), the go2
      # runs that ended without arriving, and the trip's status
      # (:pending, :arrived, :failed or :cancelled).
      #
      # @return [Integer, String, Symbol]
      attr_reader :place, :attempts, :status

      # @param place [Integer, String] a room id, "u" uid or map tag (what go2 takes)
      # @param scripts [#start, #running?, #kill] default Lich's Script
      # @param at [#call] (world, place) -> Boolean; default by room id, uid or tag
      # @param unhide [Boolean] send UNHIDE before starting, as go2 does
      # @param attempts [Integer] go2 runs allowed before could_not_reach
      # @param retry_delay [Numeric] seconds before the next attempt after
      #   a go2 that ended short (a pathing error exits at once)
      # @param clock [#now] the time source; Time, or a fake in specs
      def initialize(place, scripts: nil, at: nil, unhide: true, attempts: ATTEMPTS, retry_delay: RETRY_DELAY, clock: Time)
        @place = place
        @scripts = scripts || EO::Engine::Behaviors::Rest::LichScripts
        @at = at
        @unhide = unhide
        @max = attempts
        @retry_delay = retry_delay
        @clock = clock
        @retry_at = nil
        @attempts = 0
        @started = false
        @status = :pending
        @blocked_cause = nil
      end

      # Arrived, failed or cancelled: nothing more to tick.
      #
      # @return [Boolean]
      def done? = %i[arrived failed cancelled].include?(@status)

      # nil while underway; a Result when done.
      #
      # @param world [World]
      # @return [Actions::Result, nil] success with :arrived, failed with
      #   :could_not_reach or :cancelled, nil while go2 is still walking
      def tick(world)
        return finished if done?

        if at?(world)
          # Reaching the destination is not the end of go2's lifecycle.
          # go2 may still be restoring weapons or other travel-managed gear;
          # let that cleanup finish before handing control back to combat.
          return nil if @started && @scripts.running?(SCRIPT)

          @status = :arrived
          Travel.release(self)
          Events.emit(:travel_arrived, place: @place, attempts: @attempts)
          return finished
        end

        if @started && (blocked = Travel.blocked_status) && terminal?(blocked)
          stop_script
          @started = false
          @status = :failed
          @blocked_cause = blocked.cause
          Travel.release(self)
          Events.emit(:travel_blocked, place: @place, cause: blocked.cause,
                                       reason: blocked.reason, command: blocked.command)
          return finished
        end

        if @started && !@scripts.running?(SCRIPT)
          @attempts += 1
          @started = false
          if @attempts >= @max
            @status = :failed
            Travel.release(self)
            Events.emit(:travel_failed, place: @place, attempts: @attempts)
            return finished
          end
          @retry_at = @clock.now + @retry_delay
        end

        unless @started
          return nil if @retry_at && @clock.now < @retry_at

          @retry_at = nil
          Travel.claim(self)
          unhide(world) if @unhide && world.me.hidden?
          @scripts.start(SCRIPT, "#{@place} --disable-confirm")
          @started = true
          Events.emit(:travel_started, place: @place, attempt: @attempts + 1)
        end
        nil
      end

      # go2 has been started and the trip is not done.
      #
      # @return [Boolean]
      def underway? = @started && !done?

      # The holder lost control: end go2 now, keep the trip. The next
      # tick starts go2 again from wherever we are, not as a new attempt.
      #
      # @return [void]
      def suspend!
        return unless underway?

        stop_script
        @started = false
        Events.emit(:travel_suspended, place: @place)
      end

      # The engine is stopping or the holder changed its mind.
      #
      # @return [void]
      def cancel!
        return if done?

        stop_script
        @status = :cancelled
        Travel.release(self)
      end

      # Why go2 gave up, when it told us: a cause symbol from
      # Lich::Common::Move (:injured, :encumbered, ...), else nil. Read it
      # after a :could_not_reach to know whether walking again is futile.
      #
      # @return [Symbol, nil]
      attr_reader :blocked_cause

      private

      # A blocked status this trip should end on rather than wait out.
      # Travel.claim clears the board when a run starts, so what is here
      # was reported by this trip's own go2.
      def terminal?(status)
        return false unless status.respond_to?(:cause)

        TERMINAL_CAUSES.include?(status.cause)
      end

      def stop_script
        @scripts.kill(SCRIPT) if @started && @scripts.running?(SCRIPT)
      end

      def finished
        case @status
        when :arrived then Actions::Result.new(status: :success, reason: :arrived)
        when :failed then Actions::Result.new(status: :failed, reason: :could_not_reach)
        else Actions::Result.new(status: :failed, reason: :cancelled)
        end
      end

      # Where go2 takes us: a map id, a "u" server uid, or a map tag.
      def at?(world)
        return @at.call(world, @place) if @at

        place = @place.to_s
        case place
        when /\A\d+\z/ then world.room.id == place.to_i
        when /\Au-?(\d+)\z/i then world.room.uid.to_s == Regexp.last_match(1)
        else world.room.tags.include?(place)
        end
      rescue StandardError
        false
      end

      def unhide(world)
        Actions::Command.new(world, command: 'unhide').call
      end
    end

    # The travel seam Rest and Wander take: a callable of (room) that
    # answers a Trip to tick, or, for the old blocking style and for
    # specs, true/false. +Travel.step+ drives either one.
    #
    # @return [Proc] (room) -> Trip
    def self.default = ->(room) { Trip.new(room) }

    # One tick of the holder's trip to +room+, starting one when the
    # holder has none.
    #
    # @param holder [Object] the behavior; keeps its trip in @trip
    # @param travel [#call] (room) -> Trip or Boolean; see +default+
    # @param room [Integer, String] where to go, as go2 takes it
    # @param world [World]
    # @return [Symbol] :arrived, :underway, :failed (one blocking attempt
    #   that did not arrive), or :could_not_reach (a Trip's attempts spent)
    def self.step(holder, travel, room, world)
      trip = holder.instance_variable_get(:@trip)
      trip ||= travel.call(room)
      unless trip.respond_to?(:tick)
        holder.instance_variable_set(:@trip, nil)
        return trip ? :arrived : :failed
      end

      holder.instance_variable_set(:@trip, trip)
      result = trip.tick(world)
      return :underway if result.nil?

      holder.instance_variable_set(:@trip, nil)
      return :arrived if result.success?

      result.reason == :could_not_reach ? :could_not_reach : :failed
    end

    # Cancel a holder's trip, if any (the engine's stop).
    #
    # @param holder [Object] the behavior; its trip is in @trip
    # @return [void]
    def self.cancel(holder)
      trip = holder.instance_variable_get(:@trip)
      trip&.cancel! if trip.respond_to?(:cancel!)
      holder.instance_variable_set(:@trip, nil)
    end

    # Suspend a holder's trip, if any (the engine handed control to
    # another behavior). The trip stays on the holder and resumes when
    # its next step is taken.
    #
    # @param holder [Object] the behavior; its trip is in @trip
    # @return [void]
    def self.suspend(holder)
      trip = holder.instance_variable_get(:@trip)
      trip.suspend! if trip.respond_to?(:suspend!)
    end

    # --- ownership: one go2 at a time --------------------------------------

    # The trip whose go2 is running, if any.
    #
    # @return [Trip, nil]
    def self.active = @active

    # True while a supervised go2 owns movement. Other movement behaviors
    # yield until it arrives or ends; Survival still remains free to handle
    # death, entrapment, or other conditions that outrank ordinary movement.
    #
    # @return [Boolean]
    def self.underway? = @active&.underway? == true

    # A trip about to start go2 takes the script from any other trip
    # still underway (a preempted holder's, suspended late).
    #
    # @param trip [Trip] the trip starting go2
    # @return [Trip] the new active trip
    def self.claim(trip)
      @active.suspend! if @active && !@active.equal?(trip) && @active.respond_to?(:suspend!)
      # A block belongs to the go2 run that reported it. Starting a new
      # run clears it, so a fresh trip is never ended by the last one's
      # blocker before its own go2 has said anything.
      @blocked_status = nil
      @active = trip
    end

    # A trip that arrived, failed or was cancelled gives up the script;
    # another trip's claim is left alone.
    #
    # @param trip [Trip]
    # @return [void]
    def self.release(trip)
      @active = nil if @active.equal?(trip)
    end

    # --- go2's own account of the trip -------------------------------------

    # Causes that no amount of walking fixes: go2 will keep restarting and
    # never move, so the trip ends now and the behavior ladder takes over.
    # Rest (20) outranks Wander (60) and already owns wounded and
    # encumbered, including the profile's healing; Survival (0) owns the
    # room being dangerous. A Trip that heals would be a second copy of
    # both, so it does neither: it reports why and gets out of the way.
    TERMINAL_CAUSES = %i[injured encumbered].freeze

    # Causes go2 clears on its own: a roundtime ends, a door opens, a
    # muckle wears off. Staying underway is right for these.
    TRANSIENT_CAUSES = %i[roundtime closed muckled].freeze

    # The blocked status go2 last reported, or nil when it is walking.
    #
    # @return [Object, nil] go2's frozen Status snapshot
    def self.blocked_status = @blocked_status

    # Subscribe to go2's status board, once per process. Every change
    # arrives as +:go2_status+ on the engine bus for the logger, and a
    # blocked phase is kept for the active Trip to read on its next tick.
    #
    # Events-only by choice: on a Lich without the primitive nothing
    # subscribes and a Trip behaves exactly as it did before, blind but
    # working. Delivery is on go2's thread, so this does the least
    # possible work here and lets the trip act on its own tick.
    #
    # @return [Boolean] whether a subscription was made
    def self.listen!
      return false if @listening
      return false unless defined?(::Lich::Common::Events)

      ::Lich::Common::Events.on('go2.status', name: 'eohunter') do |_topic, status|
        note_status(status)
      end
      @listening = true
    rescue StandardError
      false
    end

    # Record a status change. Kept tiny: it runs on go2's thread.
    #
    # @param status [Object] go2's Status snapshot
    # @return [void]
    def self.note_status(status)
      @blocked_status = status.phase == :blocked ? status : nil
      Events.emit(:go2_status, phase: status.phase, cause: status.cause,
                                reason: status.reason, command: status.command)
    rescue StandardError
      nil
    end

    # Specs and a fresh run.
    #
    # @return [nil]
    def self.reset!
      @blocked_status = nil
      @active = nil
    end
  end
end
