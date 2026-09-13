# frozen_string_literal: true

# ============================================================================
# engine (from forge engine.rb)
# ============================================================================

#
# EO::Engine::Engine - the tick loop and priority arbiter.
#
# Each tick: run watchdogs, pick the highest-priority behavior that wants
# control, let it issue one verified action. Intent is re-derived from
# World every tick. The engine prefers halting cleanly (stop! with reason)
# to grinding on a confused state.
#
module EO::Engine
  # The tick loop and priority arbiter; see the file header.
  class Engine
    # Why the engine stopped: the first reason handed to `stop!`.
    #
    # @return [Symbol, nil] nil while running
    attr_reader :stop_reason

    # last_evaluations: the arbiter view of the last tick, [[name, wanted]]
    # in priority order down to the behavior that took control (the ones
    # below it were not asked). Answers "why is it resting instead of
    # fighting" from the status line or a watchdog trip.
    #
    # @return [Array<Array(String, Boolean)>]
    attr_reader :last_evaluations

    # @param world [World]
    # @param behaviors [Array<Behavior>] sorted here by priority
    # @param interval [Numeric] seconds slept after each tick
    # @param max_consecutive_failures [Integer] failed actions in a row that trip the watchdog
    # @param clock [#call] returns the current Time; injectable for specs
    def initialize(world:, behaviors:, interval: 0.25, max_consecutive_failures: 5, clock: -> { Time.now })
      @world = world
      @behaviors = behaviors.sort_by(&:priority)
      @interval = interval
      @max_failures = max_consecutive_failures
      @clock = clock
      @stopping = false
      @stop_reason = nil
      @consecutive_failures = 0
      @fires = Hash.new { |h, k| h[k] = [] }
      @last_evaluations = []
      @holder = nil
      @on_tick = []
      @on_tick_completed = []
      @completed_ticks = 0
      @pause_owners = {}
      @pause_mutex = Mutex.new
    end

    # Fires inside each budgeted behavior's window right now, `{name => count}`.
    #
    # @param now [Time] the moment to count back from
    # @return [Hash{String => Integer}] behaviors without a budget are left out
    def fire_counts(now = @clock.call)
      @behaviors.each_with_object({}) do |b, out|
        _limit, window = budget_of(b)
        next if window.nil?

        out[b.name] = @fires[b.name].count { |t| now - t <= window }
      end
    end

    # A block run at the start of every tick, paused or not: the group
    # heartbeat and the follower's report live here.
    #
    # @yield [world] at the start of every tick
    # @yieldparam world [World]
    # @return [Proc] the block, as registered
    def on_tick(&block)
      @on_tick << block
      block
    end

    # Observe the owner's completed turn, after arbitration and watchdogs.
    # Paused turns complete after handing off control; aborted turns do not.
    # The callback must only copy local state and must not perform network I/O.
    #
    # @yield [world, tick, status] after a completed turn, before the interval sleep
    # @yieldparam world [World]
    # @yieldparam tick [Integer] increasing completed-turn number in this engine
    # @yieldparam status [Hash] the owner's status at completion
    # @return [Proc] the block, as registered
    def on_tick_completed(&block)
      @on_tick_completed << block
      block
    end

    # End the run after the current tick; the first reason given is kept.
    #
    # @param reason [Symbol] why (a watchdog kind, :engine_error, the user's stop)
    # @return [void]
    def stop!(reason)
      @stopping = true
      @stop_reason ||= reason
      # A trip in flight (Rest, Wander) is a go2 script to kill.
      @behaviors.each { |b| b.cancel! if b.respond_to?(:cancel!) }
    end

    # @return [Boolean] true once `stop!` has been called
    def stopping? = @stopping

    # Hold in place without tearing down the session. Independent owners
    # cannot release one another's holds; legacy calls own the manual hold.
    #
    # @param owner [Object] stable local ownership key, never a remote reference
    # @return [true]
    def pause!(owner: :manual)
      @pause_mutex.synchronize { @pause_owners[owner] = true }
    end

    # Lift only this owner's hold. Other holds still prevent arbitration.
    #
    # @param owner [Object] the same local key passed to pause!
    # @return [false]
    def resume!(owner: :manual)
      @pause_mutex.synchronize { @pause_owners.delete(owner) }
      false
    end

    # @return [Boolean] true while any owner holds the engine
    def paused? = @pause_mutex.synchronize { !@pause_owners.empty? }

    # A frozen snapshot for the status line: state (:running, :held,
    # :stopped), reason, the behavior holding control, every behavior's
    # name, and the failure streak.
    #
    # @return [Hash{Symbol => Object}]
    def status
      {
        state: @stopping ? :stopped : (paused? ? :held : :running),
        reason: @stop_reason,
        behavior: @holder&.name,
        behaviors: @behaviors.map(&:name).freeze,
        consecutive_failures: @consecutive_failures
      }.freeze
    end

    # Tick until stopped, with :engine_started and :engine_stopped on the bus
    # around the loop.
    #
    # @return [Symbol, nil] the stop reason
    def run
      Events.emit(:engine_started, behaviors: @behaviors.map(&:name))
      tick until @stopping
      Events.emit(:engine_stopped, reason: @stop_reason)
      @stop_reason
    end

    # One tick: the on_tick callbacks, then (unless stopped or paused) the
    # room note, the arbiter walk, the chosen behavior's turn, the
    # watchdogs, and the interval sleep. Ordinary exceptions are an
    # :engine_error on the bus and a stop. Native execution-guard interrupts
    # propagate to the owning supervisor; they are not engine failures.
    #
    # @return [void]
    # @raise [Lich::Common::ScriptExecutionGuard::Interrupted] the native owner
    #   must reconcile a refused execution scope before any further work
    def tick
      @on_tick.each { |b| b.call(@world) }
      # A callback may have stopped the engine (a lost leader, a lost
      # member, the rescued child): nothing acts after that.
      return if @stopping

      if paused?
        hand_off(nil)
        complete_tick
        sleep(@interval)
        return
      end

      note_room
      behavior = choose
      hand_off(behavior)
      if behavior
        result = behavior.tick(@world)
        track(behavior, result)
      else
        idle
      end
      complete_tick
      sleep(@interval) unless @stopping
    rescue StandardError => e
      if defined?(::Lich::Common::ScriptExecutionGuard::Interrupted) && e.is_a?(::Lich::Common::ScriptExecutionGuard::Interrupted)
        raise
      end

      # Carry the backtrace: an engine_error that reports only a reason
      # ends the run with nothing to debug from. Forge frames only - the
      # Lich/gem frames below them are never where the bug is.
      frames = Array(e.backtrace).select { |f| f =~ %r{eohunter}i }.first(8)
      Events.emit(:engine_error, error: e.class.name, message: e.message,
                                 backtrace: frames.empty? ? Array(e.backtrace).first(8) : frames)
      stop!(:engine_error)
    end

    private

    def complete_tick
      @completed_ticks += 1
      return if @on_tick_completed.empty?

      completed_status = status
      @on_tick_completed.each { |callback| callback.call(@world, @completed_ticks, completed_status) }
    end

    # The room transition, seen here before any behavior is chosen, so
    # the room-scoped state (Engage's (room) commands, Loot's looted
    # list, Survival's flags) resets even when a fight is already waiting
    # in the new room and a follower never wanders.
    def note_room
      id = @world.room.id
      return if id == @room_id

      @room_id = id
      Events.emit(:entered_room, room: id)
    end

    # Control changed hands: the behavior that had it last is told, so a
    # trip it has in flight (Rest, Wander) stops moving us while someone
    # else is issuing commands. Also on pause and on idle.
    def hand_off(behavior)
      return if @holder.equal?(behavior)

      previous = @holder
      @holder = behavior
      return unless previous.respond_to?(:preempted!)

      previous.preempted!(@world)
      Events.emit(:preempted, from: previous.name, to: behavior&.name)
    end

    # The arbiter walk: highest priority first, stopping at the first
    # behavior that wants control. Each guard runs once; the behaviors
    # below the chosen one are not asked, so the trace holds only what
    # was actually evaluated this tick.
    def choose
      @last_evaluations = []
      muckled = @world.me.muckled?
      @behaviors.each do |b|
        # A muckled character cannot act, and every action below Cleanse
        # refuses with :muckled before it sends. A behavior that keeps
        # winning the arbiter through a stun spends the stun refusing
        # itself and starves the ones that could get us out. bigshot never
        # reaches this because bs_put waits the stun out inside the send.
        next if muckled && !b.runs_muckled?

        wanted = b.wants_control?(@world)
        @last_evaluations << [b.name, wanted]
        return b if wanted
      end
      nil
    end

    # Two watchdogs; either trip halts, and a human (or the task layer)
    # looks. Repeated failures: N failed actions in a row means our model
    # of the world is wrong. Fire budget: more commands on the wire in a
    # window than roundtime allows means the behavior is looping on
    # successes (a retarget probe, a re-search) with nothing slowing it
    # down. The budget counts `acted?`, which only Actions::Base stamps
    # at its send seam: a status is the behavior's own account of a tick,
    # and a gate refusal or a stance no-op can say :failed or :success
    # without the game ever hearing a command.
    def track(behavior, result)
      if result.respond_to?(:failed?) && result.failed?
        @consecutive_failures += 1
        if @consecutive_failures >= @max_failures
          # The reason the last action gave is the whole diagnosis, and it
          # was in hand here and thrown away: a stop said which behavior
          # and how many, never what the game refused.
          trip(:repeated_failures, behavior, @consecutive_failures,
               reason: result.respond_to?(:reason) ? result.reason : nil,
               line: result.respond_to?(:line) ? result.line : nil)
          return
        end
      elsif result.respond_to?(:success?) && result.success?
        @consecutive_failures = 0
      end
      count_fire(behavior, result)
    end

    def count_fire(behavior, result)
      limit, window = budget_of(behavior)
      return if limit.nil? || window.nil?
      return unless result.respond_to?(:acted?) && result.acted?

      now = @clock.call
      fires = @fires[behavior.name]
      fires << now
      fires.shift while now - fires.first > window
      trip(:fire_budget, behavior, fires.size) if fires.size > limit
    end

    def trip(kind, behavior, count, reason: nil, line: nil)
      Events.emit(:watchdog_tripped, kind: kind, behavior: behavior.name, count: count,
                                     reason: reason, line: line,
                                     evaluations: @last_evaluations.dup)
      stop!(kind)
    end

    def budget_of(behavior)
      return nil unless behavior.respond_to?(:fire_budget)

      behavior.fire_budget
    end

    def idle = nil
  end
end
