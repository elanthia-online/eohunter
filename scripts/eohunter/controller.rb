# frozen_string_literal: true

# Native, exact-instance supervision for agent-run hunts. LAB owns admission and
# the expiring lease; eohunter continues to own combat, travel, rest and cleanup.
module EO::Engine
  # Native, exact-instance supervision for agent-run hunts. LAB owns
  # admission and the expiring lease; eohunter continues to own combat,
  # travel, rest and cleanup.
  module Controller
    # A launch, profile, control or lease that the controller refuses.
    class Invalid < StandardError; end

    # Deep-frozen copies of the hashes, arrays, strings and times the
    # controller hands out, so a later tick cannot rewrite an earlier one.
    module Immutable
      module_function

      # A frozen deep copy: hashes and arrays recursively, strings and
      # times dup'd, everything else as it is.
      #
      # @param value [Object]
      # @return [Object] the frozen copy
      def copy(value)
        result = case value
                 when Hash then value.each_with_object({}) { |(key, item), out| out[key] = copy(item) }
                 when Array then value.map { |item| copy(item) }
                 when String, Time then value.dup
                 else value
                 end
        result.freeze
      end
    end

    # The launch argument carrying the work and cleanup deadlines.
    START_FLAG = '--supervised-start-v1'
    # The launch argument carrying the refuge room and the return deadline.
    REFUGE_FLAG = '--supervised-refuge-v1'

    # The supervised launch: monotonic-clock deadlines for work, cleanup
    # and the return, and the refuge room the hunt starts and ends in.
    Launch = Struct.new(:work_deadline, :cleanup_deadline, :refuge_room, :return_deadline, keyword_init: true) do
      # Pull the two supervised flags and their values out of the script
      # arguments. Both or neither must be present, and the deadlines must
      # be ordered: work, then cleanup within 10 s, then the return 10-120 s
      # later, all within 300 s of now.
      #
      # @param arguments [Array<String>] the script's option words
      # @param clock [#call] the monotonic time source
      # @return [Array(Launch, Array<String>), Array(nil, Array<String>)] the
      #   frozen launch (nil when unsupervised) and the remaining arguments
      # @raise [Invalid] one flag without the other, a malformed value, or
      #   deadlines out of order or expired
      def self.extract!(arguments, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        args = arguments.dup
        start_values = remove_pair(args, START_FLAG)
        refuge_values = remove_pair(args, REFUGE_FLAG)
        return [nil, args] unless start_values || refuge_values
        raise Invalid, 'both supervised controller selectors are required' unless start_values && refuge_values

        work, cleanup = numeric_pair(start_values, 'execution window')
        room, return_at = refuge_pair(refuge_values)
        now = clock.call
        unless now.is_a?(Numeric) && now.finite? && work > now && cleanup > work && cleanup - work <= 10 &&
               return_at > cleanup && (return_at - cleanup).between?(10, 120) && return_at - now <= 300
          raise Invalid, 'supervised controller deadlines are invalid or expired'
        end

        [new(work_deadline: work, cleanup_deadline: cleanup, refuge_room: room, return_deadline: return_at).freeze, args]
      end

      # The profile must be bounded, rest in the registered refuge, run no
      # child scripts, and never log out or depart on death.
      #
      # @param profile [Profile] the loaded bigshot profile
      # @return [Boolean] true
      # @raise [Invalid] when any of those conditions fails
      def admit_profile!(profile)
        raise Invalid, 'controlled hunts require a single fixed refuge, not Field/Town Rest' if profile['field_rest_room_id']
        if profile['preparations'] && !profile['preparations'].empty?
          raise Invalid, 'controlled hunts do not yet admit preparations with profile-owned command authority'
        end

        unless profile['resting_room_id'].is_a?(Integer) && profile['resting_room_id'] == refuge_room &&
               profile['hunting_room_id'].is_a?(Integer) && !profile['hunting_boundaries'].empty?
          raise Invalid, 'controlled hunt requires a bounded profile whose resting room is the registered refuge'
        end
        if profile['loot_script'] || !profile['resting_scripts'].empty? || !profile['hunting_scripts'].empty?
          raise Invalid, 'controlled hunt does not yet admit profile child scripts; use native looting and commands'
        end
        if profile['dead_man_switch'] || profile['depart_switch']
          raise Invalid, 'controlled hunt cannot log out or depart on death'
        end
        true
      end

      class << self
        private

        def remove_pair(args, flag)
          indexes = args.each_index.select { |index| args[index] == flag }
          raise Invalid, "#{flag} must occur exactly once" if indexes.length > 1
          return nil if indexes.empty?

          index = indexes.first
          raise Invalid, "#{flag} requires one value" unless args[index + 1] && !args[index + 1].start_with?('--')
          args.slice!(index, 2).last
        end

        def numeric_pair(value, label)
          parts = value.to_s.split(',', -1)
          raise Invalid, "#{label} must contain exactly two deadlines" unless parts.length == 2

          numbers = parts.map { |part| Float(part, exception: false) }
          raise Invalid, "#{label} deadlines must be finite" unless numbers.all? { |number| number&.finite? }

          numbers
        end

        def refuge_pair(value)
          room, return_at = value.to_s.split(',', -1)
          unless room&.match?(/\A[1-9]\d*\z/) && room != '4'
            raise Invalid, 'supervised refuge must be an explicit room other than 4'
          end
          deadline = Float(return_at, exception: false)
          raise Invalid, 'supervised refuge deadline must be finite' unless deadline&.finite?

          [room.to_i, deadline]
        end
      end
    end

    # A finite, predeclared sequence of profile routines. LAB may choose only a
    # manifest-enumerated sequence; eohunter owns target selection, execution,
    # measurement and the decision to stop exposing the character.
    class TrialSequence
      # The argument word that introduces the routine sequence.
      KEYWORD = 'trial'
      # Routines one sequence may hold.
      MAX_TRIALS = 5
      # Resolved actions one trial may spend before it fails.
      MAX_ACTIONS_PER_TRIAL = 12
      # Seconds one trial may run before it fails.
      MAX_SECONDS_PER_TRIAL = 45

      # Why the sequence failed; nil while running or complete.
      # @return [String, nil]
      attr_reader :failure

      # Pull "trial <letters>" out of the script arguments: one to
      # MAX_TRIALS routine letters a-j, separated by commas or dashes.
      #
      # @param arguments [Array<String>] the script's option words
      # @param clock [#call] the monotonic time source
      # @return [Array(TrialSequence, Array<String>), Array(nil, Array<String>)]
      #   the sequence (nil when absent) and the remaining arguments
      # @raise [Invalid] the word twice, no value, or bad letters
      def self.extract!(arguments, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        args = arguments.dup
        indexes = args.each_index.select { |index| args[index].to_s.casecmp?(KEYWORD) }
        raise Invalid, 'trial may occur only once' if indexes.length > 1
        return [nil, args] if indexes.empty?

        index = indexes.first
        value = args[index + 1]
        raise Invalid, 'trial requires a comma-separated routine sequence' if value.nil?

        routines = value.to_s.downcase.split(/[,-]/, -1)
        unless routines.length.between?(1, MAX_TRIALS) && routines.all? { |letter| letter.match?(/\A[a-j]\z/) }
          raise Invalid, "trial routines must be 1-#{MAX_TRIALS} letters from a through j"
        end
        args.slice!(index, 2)
        [new(routines, clock: clock), args]
      end

      # @param routines [Array<String>] the routine letters, in order
      # @param clock [#call] the monotonic time source
      # @param recording_context [#call, nil] optional combat recorder
      #   attribution captured when a target is selected
      def initialize(routines, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                     recording_context: nil)
        @routines = Array(routines).map(&:to_s).freeze
        @clock = clock
        @recording_context = recording_context || lambda do
          ::Lich::Gemstone::Combat::Tracker.observation_context
        end
        @mutex = Mutex.new
        @cursor = 0
        @results = []
        @active = nil
        @failure = nil
      end

      # Every routine letter must have commands in the profile
      # (hunting_commands for a, hunting_commands_<letter> for the rest).
      #
      # @param profile [Profile]
      # @return [Boolean] true
      # @raise [Invalid] naming the empty routines
      def admit_profile!(profile)
        missing = @routines.uniq.reject do |letter|
          key = letter == 'a' ? 'hunting_commands' : "hunting_commands_#{letter}"
          Array(profile[key]).any?
        end
        raise Invalid, "trial routines are empty in the reviewed profile: #{missing.join(', ')}" if missing.any?

        true
      end

      # Injected into Engage at its existing routine-selection seam. Opens
      # the next trial on the first call for a creature and answers its
      # routine letter on every call after.
      #
      # @param creature [GameObj] the target Engage chose
      # @param _default [String] Engage's own choice, unused
      # @return [String] the routine letter for the active trial
      # @raise [Invalid] the sequence is already complete
      def select(creature, _default)
        @mutex.synchronize do
          raise Invalid, 'trial sequence is already complete' if complete_locked?
          id = creature.id.to_s
          # A live target switch is a trial-protocol case, not an engine
          # fault. Engage switches targets on its own when priority is set
          # and a better-ranked creature walks in (targets.rb 328), and
          # select is called from inside Engage's tick: raising here goes
          # through Engine#tick's blanket rescue, which reports
          # :engine_error and stops the whole supervised run. Fail the
          # trial instead and hand Engage a letter so its tick finishes.
          if @active && @active[:target_id] != id
            letter = @active[:routine]
            # select has no World, so the abandoned trial is recorded
            # with what it does have rather than dropped: the report
            # should show the trial that was open when this happened.
            @results << @active.merge(
              outcome: 'target_switched', finished_at: @clock.call,
              elapsed_seconds: (@clock.call - @active[:started_at]).round(3)
            )
            @failure = 'target_switched'
            @active = nil
            return letter
          end
          @active ||= {
            index: @cursor + 1, routine: @routines.fetch(@cursor), target_id: id,
            creature: creature_data(creature), started_at: @clock.call,
            recording_context: capture_recording_context,
            actions: [], samples: []
          }
          @active[:routine]
        end
      end

      # Optional attribution metadata must never stop the combat owner.
      def capture_recording_context
        Immutable.copy(@recording_context.call)
      rescue StandardError
        nil
      end
      private :capture_recording_context

      # Called once per owner-thread controller checkpoint, before another
      # engine action. Returns :complete, :failed, or nil. While the target
      # is still on the target list it samples and enforces the per-trial
      # limits; once it is gone, a dead creature closes the trial and any
      # other loss fails the sequence.
      #
      # @param world [World]
      # @return [Symbol, nil] :complete, :failed, or nil to keep going
      def tick(world)
        @mutex.synchronize do
          return :failed if @failure
          return :complete if complete_locked?
          return nil unless @active

          target = Array(world.room.targets).find { |item| item.id.to_s == @active[:target_id] }
          if target
            sample_locked(world, target)
            if @active[:actions].length >= MAX_ACTIONS_PER_TRIAL || @clock.call - @active[:started_at] >= MAX_SECONDS_PER_TRIAL
              finish_locked(world, target, 'limit_reached')
              @active = nil
              @failure = 'trial_limit_reached'
              return :failed
            end
            return nil
          end

          observed = Array(world.room.creatures).find { |item| item.id.to_s == @active[:target_id] }
          outcome = observed&.status.to_s.match?(/dead/i) ? 'killed' : 'target_lost'
          finish_locked(world, observed, outcome)
          unless outcome == 'killed'
            @active = nil
            @failure = outcome
            return :failed
          end

          @cursor += 1
          @active = nil
          complete_locked? ? :complete : nil
        end
      end

      # Record a :routine_action_resolved event against the active trial
      # when it names the trial's target; every other event is ignored.
      #
      # @param event [Events::Event]
      # @return [void]
      def observe(event)
        return unless event.type == :routine_action_resolved

        @mutex.synchronize do
          return unless @active && event.data[:target].to_s == @active[:target_id]

          @active[:actions] << action_data(event)
        end
      end

      # A frozen snapshot: state ("running", "complete" or "failed"), the
      # planned letters, the current index, the failure, the finished
      # results and the active trial.
      #
      # @return [Hash] deep-frozen
      def status
        @mutex.synchronize do
          Immutable.copy(
            state: @failure ? 'failed' : (complete_locked? ? 'complete' : 'running'),
            planned: @routines, current: @active && @active[:index],
            failure: @failure, results: @results, active: @active
          )
        end
      end

      private

      def complete_locked? = @cursor >= @routines.length && @active.nil?

      def creature_data(creature)
        return {} unless creature

        %i[id name noun type status].to_h do |key|
          value = creature.respond_to?(key) ? creature.public_send(key) : nil
          [key, value.nil? ? nil : value.to_s]
        end
      end

      def resources(world)
        %i[mana health spirit stamina].to_h do |name|
          value = world.me.respond_to?(name) ? world.me.public_send(name) : nil
          [name, value.nil? ? nil : value.to_i]
        end
      end

      def sample_locked(world, target)
        state = creature_state(world, @active[:target_id])
        sample = { at: @clock.call, resources: resources(world), creature: creature_data(target), state: state }
        comparable = sample.reject { |key, _| key == :at }
        previous = @active[:samples].last
        @active[:samples] << sample if previous.nil? || previous.reject { |key, _| key == :at } != comparable
        @active[:samples].shift while @active[:samples].length > MAX_ACTIONS_PER_TRIAL + 2
      end

      def action_data(event)
        before = Hash(event.data[:resources_before])
        after = Hash(event.data[:resources_after])
        spent = before.each_with_object({}) do |(name, value), out|
          next if value.nil? || after[name].nil?

          out[name] = [value.to_i - after[name].to_i, 0].max
        end
        {
          at: event.at.to_f, command: event.data[:command].to_s[0, 200],
          status: event.data[:status].to_s, reason: event.data[:reason]&.to_s,
          line: event.data[:line].to_s[0, 300], spent: spent
        }
      end

      def finish_locked(world, creature, outcome)
        sample_locked(world, creature) if creature
        finished = @active.merge(
          outcome: outcome, finished_at: @clock.call,
          elapsed_seconds: (@clock.call - @active[:started_at]).round(3),
          final_resources: resources(world),
          final_creature_state: creature_state(world, @active[:target_id])
        )
        @results << finished
      end

      # Read the current core CreatureInstance through World's existing seam.
      # Copy before retaining it: later combat must not rewrite an earlier sample.
      def creature_state(world, id)
        Immutable.copy(world.creature(id)&.essential_data)
      end
    end

    # Sticky lease and state guard shared by the owner and its exact go2 child.
    # Any failed observation permanently revokes the run.
    class Guard
      # Wire sends the guard has permitted so far.
      # @return [Integer]

      # @param owner [Script] the eohunter script instance
      # @param snapshot [#call] -> Hash; the controller_snapshot lambda
      # @param launch [Launch] the deadlines the lease runs against
      # @param clock [#call] the monotonic time source
      def initialize(owner:, snapshot:, launch:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @owner, @snapshot, @launch, @clock = owner, snapshot, launch, clock
        @mutex = Mutex.new
        @predicate = nil
        @activated = false
        @revoked = false
        @phase = :work
      end

      # Bind the supervisor's validity predicate, once, and take the first
      # observation. A failed first observation revokes the run for good.
      #
      # @param predicate [Proc] -> true while the supervisor's lease holds
      # @return [Boolean] activated; false for a non-Proc, a second call, a
      #   revoked guard, or a failed observation
      def activate(predicate)
        return false unless predicate.is_a?(Proc)

        @mutex.synchronize do
          return false if @predicate || @revoked

          @predicate = predicate
        end
        valid = valid_observation?(predicate, :work, nil)
        @mutex.synchronize do
          @activated = valid
          @revoked = true unless valid
        end
        valid
      end

      # @return [Boolean] activated and not since revoked
      def activated? = @mutex.synchronize { @activated && !@revoked }

      # Which deadline observations run against: :work or :return.
      # @param value [Symbol]
      # @return [Symbol] the value set
      def phase=(value)
        @mutex.synchronize { @phase = value }
      end

      # The execution-guard check Lich calls before a send, and the
      # controller calls each tick. One failed observation revokes the run.
      #
      # @param wire [String, nil] the line about to go out; nil for a tick
      #   check, which skips the stability requirement and counts no send
      # @return [Boolean] permitted
      def permitted?(wire)
        predicate, phase, activated, revoked = @mutex.synchronize { [@predicate, @phase, @activated, @revoked] }
        return false if revoked || !activated || !predicate

        valid = valid_observation?(predicate, phase, wire)
        unless valid
          revoke!
          return false
        end
        true
      rescue StandardError
        revoke!
        false
      end

      # Fix the session identity every later observation must match.
      #
      # @param session [String, #to_s] the snapshot's session string
      # @return [String] the frozen identity
      # @raise [Invalid] an empty identity, or one already bound
      def bind_session!(session)
        value = session.to_s
        raise Invalid, 'controlled session identity is unavailable' if value.empty?

        @mutex.synchronize do
          raise Invalid, 'controlled session is already bound' if @session

          @session = value.freeze
        end
      end

      # Revoke the run permanently.
      # @return [Boolean] false, so a caller can return it as "not permitted"
      def revoke!
        @mutex.synchronize { @revoked = true }
        false
      end

      # @return [Boolean]
      def revoked? = @mutex.synchronize { @revoked }

      private

      def valid_observation?(predicate, phase, wire)
        return false unless predicate.call == true

        now = @clock.call
        limit = phase == :return ? @launch.return_deadline : @launch.work_deadline
        observed = @snapshot.call
        valid = now.is_a?(Numeric) && now.finite? && now < limit && observed.is_a?(Hash) &&
                observed[:owner] == true && observed[:connected] == true && observed[:alive] == true &&
                observed[:session] == @session
        valid &&= observed[:stable] == true unless wire.nil?
        valid
      end
    end

    # The only child-process seam admitted by the first controller version.
    # It owns exact handles; it never kills or exempts a script by name alone.
    class ChildScripts
      # The child script names a controlled hunt may start.
      ALLOWED = ['go2'].freeze

      # Seconds to wait for a killed child's cleanup before starting a new
      # one of the same name. go2 unwinds in well under this; the wait ends
      # the moment cleanup completes, so the bound only caps a stuck child.
      TEARDOWN_TIMEOUT = 3

      # @param owner [Script] the eohunter script instance
      # @param guard [Guard] whose permitted? each child's sends run through
      def initialize(owner:, guard:)
        @owner, @guard = owner, guard
        @mutex = Mutex.new
        @children = {}
      end

      # Start an admitted child through Script.start_child, its sends behind
      # the guard and script starts of its own disallowed. The seam Rest and
      # Travel use in place of Lich's Script.
      #
      # @param name [String] the script name (case-insensitive)
      # @param args [String, nil] its arguments
      # @return [Script] the child's exact handle
      # @raise [Invalid] not admitted, already running, or failed to start
      def start(name, args = nil)
        key = name.to_s.downcase
        raise Invalid, "controlled child #{key} is not admitted" unless ALLOWED.include?(key)
        raise Invalid, "controlled child #{key} is already running" if running?(key)

        # A handle we killed is not running? the moment it is stopping?,
        # but Lich still counts it against the duplicate check until its
        # cleanup completes (script.rb 849). kill is async, so a restart on
        # the tick after a preemption can race into :duplicate, start_child
        # answers nil, and the Invalid below ends the whole supervised run
        # over a routine re-issue of go2. Wait the old handle out first:
        # join returns on the same cleanup_complete the duplicate check
        # reads.
        await_teardown(key)

        child = Script.start_child(key, args, quiet: true,
                                              execution_guard: ->(wire) { @guard.permitted?(wire) },
                                              allow_script_starts: false)
        raise Invalid, "controlled child #{key} did not start" unless child

        @mutex.synchronize { @children[key] = child }
        child
      end

      # Wait out a handle we already killed, then forget it. Lich counts a
      # stopping script against the duplicate check until its cleanup
      # completes, and join returns on exactly that (script.rb 849, 2015).
      # Best effort: a child that will not go is left to start_child, which
      # answers nil and raises Invalid as before.
      #
      # @param key [String] the downcased script name
      # @return [void]
      def await_teardown(key)
        child = @mutex.synchronize { @children[key] }
        return if child.nil?

        child.join(TEARDOWN_TIMEOUT) if child.respond_to?(:join)
        @mutex.synchronize { @children.delete(key) if @children[key].equal?(child) }
      rescue StandardError
        nil
      end

      # Is our own handle for this name running and not stopping. A script
      # of the same name started elsewhere does not count.
      #
      # @param name [String]
      # @return [Boolean, nil]
      def running?(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        child && child.respond_to?(:running?) && child.running? && !child.stopping?
      end

      # @param name [String]
      # @return [Boolean, nil] our handle for this name is paused
      def paused?(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        child && child.respond_to?(:paused?) && child.paused?
      end

      # Kill our handle for this name, asynchronously, unless it already
      # finished.
      #
      # @param name [String]
      # @return [Boolean] false when we hold no such handle
      def kill(name)
        child = @mutex.synchronize { @children[name.to_s.downcase] }
        return false unless child

        child.kill(async: true) unless child.join(0)
        true
      end

      # Is this the go2 handle we started, still owned by the owner script.
      # Answers the owner's controller_refuge_travel_child? predicate.
      #
      # @param candidate [Script]
      # @return [Boolean, nil]
      def active_travel_child?(candidate)
        child = @mutex.synchronize { @children['go2'] }
        # Keep the exact adopted handle recognizable while Lich moves it
        # through stopping/join teardown. A name match is never sufficient.
        child && child.equal?(candidate) && @owner.child_scripts.any? { |owned| owned.equal?(candidate) }
      end

      # Stop every child we started, waiting up to the timeout for each.
      #
      # @param timeout [Numeric] seconds per child for kill_sync
      # @return [Boolean] every child finished or was killed
      def cleanup(timeout: 2)
        children = @mutex.synchronize { @children.values.dup }
        children.all? do |child|
          next true if child.join(0)

          child.respond_to?(:kill_sync) && child.kill_sync(timeout: timeout)
        end
      end
    end

    # Owner-thread state machine exposed to LAB. It does not implement hunting;
    # it supervises Engine and asks Rest to perform its existing return cycle.
    class Runtime
      # The control words request accepts.
      CONTROLS = %w[status hold resume stop retreat].freeze
      # Queued controls held before the owner thread drains them.
      MAILBOX_CAPACITY = 32
      # Engine events kept in the status, oldest dropped first.
      OBSERVATION_CAPACITY = 128

      # Verifies the start snapshot (alive, standing, stable, equipped, in
      # the refuge), binds the session to the guard and subscribes to every
      # engine event. Must be built on the owner thread that will run it.
      #
      # @param engine [Engine] the engine loop to supervise
      # @param rest [Behaviors::Rest] asked for the return cycle
      # @param world [World]
      # @param owner [Script] the eohunter script instance
      # @param guard [Guard] the lease
      # @param children [ChildScripts] cleaned up when the run ends
      # @param launch [Launch] the deadlines and refuge room
      # @param objective [TrialSequence] ticked while working, fed every event
      # @param snapshot [#call] -> Hash; the controller_snapshot lambda
      # @param clock [#call] the monotonic time source
      # @raise [Invalid] the start snapshot fails, or the session cannot bind
      def initialize(engine:, rest:, world:, owner:, guard:, children:, launch:, objective:,
                     snapshot:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @engine, @rest, @world, @owner = engine, rest, world, owner
        @guard, @children, @launch, @objective, @snapshot, @clock = guard, children, launch, objective, snapshot, clock
        @thread = Thread.current
        @mutex = Mutex.new
        @mailbox = []
        @observations = []
        @state, @phase, @reason = :starting, 'outbound', nil
        origin = verified_snapshot!
        @origin_hands = Immutable.copy(origin[:hands])
        @guard.bind_session!(origin[:session])
        @event_handler = Events.on(:any) { |event| record(event) }
        cache_status
      end

      # The last cached status: mode, state, reason, the engine's behavior,
      # the room, the work result, the objective's status, the refuge
      # phase, the recent observations and the deadlines.
      #
      # @return [Hash] deep-frozen
      def status = @mutex.synchronize { @cached_status }

      # LAB's activation: hand the guard its validity predicate.
      #
      # @param valid [Proc] -> true while the supervisor's lease holds
      # @return [Boolean] whether the guard activated
      def activate_supervised(valid:)
        @guard.activate(valid)
      end

      # Queue a control for the owner thread. "status" answers at once;
      # the rest wait in the mailbox until the next tick drains them.
      #
      # @param action [String, Symbol] one of CONTROLS
      # @param valid [Proc, nil] -> true while this control still stands;
      #   checked when the control is drained
      # @return [Hash] frozen: accepted, a reason when refused, and the status
      def request(action, valid: nil)
        name = action.to_s
        @mutex.synchronize do
          return response(false, 'invalid_control_predicate') unless valid.nil? || valid.is_a?(Proc)
          return response(false, 'unknown_control') unless CONTROLS.include?(name)
          return response(true) if name == 'status'
          return response(false, 'run_closed') if terminal?
          return response(false, 'control_queue_full') if @mailbox.length >= MAILBOX_CAPACITY

          @mailbox << [name.freeze, valid].freeze
          response(true)
        end
      end

      # The supervised loop, on the owner thread: wait for activation, start
      # Rest's pre-hunt, then each pass drain the controls, check the work
      # deadline and the guard, tick the objective, tick the engine (or Rest
      # alone once the engine has stopped during a return) and finish when
      # Rest reaches :resting in the refuge. Any lost authority fails closed.
      # Children are cleaned up on the way out.
      #
      # @return [Hash] the final status
      # @raise [ThreadError] called off the owner thread
      # @raise [Invalid] activation did not arrive within 3 s, or the start
      #   state changed while waiting
      def run
        assert_owner_thread!
        await_supervisor!
        @state = :running
        @rest.start!
        Events.emit(:engine_started, behaviors: @engine.status[:behaviors])
        until terminal?
          drain_controls
          request_return('operation_work_deadline') if @phase != 'returning' && @clock.call >= @launch.work_deadline
          unless @guard.permitted?(nil)
            fail_closed('controller_authority_lost')
            break
          end
          if @phase == 'working'
            case @objective.tick(@world)
            when :complete then request_return('objective_complete', final_loot: true)
            when :failed then request_return("objective_failed:#{@objective.failure}")
            end
          end
          if @phase == 'returning' && finish_return_if_ready
            break
          end
          guarded_tick
          if @engine.stopping? && !terminal?
            request_return("engine_stopped:#{@engine.stop_reason || 'unknown'}") unless @phase == 'returning'
          elsif @phase == 'outbound' && @rest.phase == :hunting
            @phase = 'working'
          end
          cache_status
        end
        status
      ensure
        Events.emit(:engine_stopped, reason: @reason) if @state != :starting
        Events.off(@event_handler) if @event_handler
        @children.cleanup
        cache_status
      end

      # End the run if it has not ended already: revoke the guard, stop the
      # engine, and mark it stopped as "controller_closed".
      #
      # @return [Hash] the final status
      def close
        fail_closed('controller_closed') unless terminal?
        status
      end

      private

      def terminal? = %i[completed stopped].include?(@state)

      def response(accepted, reason = nil)
        { accepted: accepted, reason: reason, status: @cached_status }.compact.freeze
      end

      def await_supervisor!
        deadline = @clock.call + 3
        until @guard.activated?
          raise Invalid, 'supervised controller startup expired' if @clock.call >= deadline

          observed = @snapshot.call
          unless observed.is_a?(Hash) && observed[:owner] == true && observed[:connected] == true &&
                 observed[:room_id] == @launch.refuge_room && observed[:hands] == @origin_hands
            raise Invalid, 'supervised controller start state changed before activation'
          end
          @owner.execution_sleep(0.01)
        end
      end

      def drain_controls
        MAILBOX_CAPACITY.times do
          action, valid = @mutex.synchronize { @mailbox.shift }
          break unless action
          unless valid.nil? || valid.call == true
            @control_error = 'control_expired_or_revoked'
            next
          end

          case action
          when 'resume'
            @control_error = @phase == 'working' ? nil : 'return_already_started'
            @engine.resume! if @phase == 'working'
          when 'hold', 'stop', 'retreat'
            request_return("manual_#{action}")
          end
        rescue StandardError
          @control_error = 'control_expired_or_revoked'
        end
      end

      def request_return(reason, final_loot: false)
        return if @phase == 'returning'

        work_state = reason == 'objective_complete' ? :completed : :stopped
        @work_result = Immutable.copy(state: work_state, reason: reason, observations: @observations.dup)
        @phase = 'returning'
        @guard.phase = :return
        @engine.resume!
        @rest.request_return!(reason, final_loot: final_loot)
      end

      def guarded_tick
        policy = ->(wire) { @guard.permitted?(wire) }
        @owner.with_execution_guard(policy, allow_script_starts: true) do
          if @phase == 'returning' && @engine.stopping?
            # The stopped engine has cancelled its trips. The controller's
            # return lease still owns the existing Rest recovery path.
            @rest.tick(@world)
          else
            @engine.tick
          end
        end
      rescue StandardError
        fail_closed(@guard.revoked? ? 'controller_authority_lost' : 'guarded_engine_error')
      end

      def finish_return_if_ready
        return false unless @rest.phase == :resting

        observed = @snapshot.call
        returned = observed.is_a?(Hash) && observed[:room_id] == @launch.refuge_room &&
                   observed[:stable] == true && observed[:destination_safe] == true
        restored = returned && observed[:standing] == true && observed[:hands] == @origin_hands
        @refuge_returned, @equipment_restored = returned, restored
        @engine.stop!(restored ? :controller_complete : :controller_handoff_failed)
        work_complete = @work_result.is_a?(Hash) && @work_result[:state] == :completed
        @state = restored && work_complete ? :completed : :stopped
        @reason = if !restored then 'refuge_equipment_unconfirmed'
                  elsif work_complete then 'completed'
                  else 'retreated'
                  end
        @phase = 'finished'
        cache_status
        true
      end

      def fail_closed(reason)
        @guard.revoke!
        @engine.stop!(reason)
        @state = :stopped
        @reason = reason
        @phase = 'finished'
        cache_status
      end

      def verified_snapshot!
        observed = @snapshot.call
        unless observed.is_a?(Hash) && observed[:room_id] == @launch.refuge_room && observed[:stable] == true &&
               observed[:destination_safe] == true && observed[:alive] == true && observed[:standing] == true &&
               observed[:owner] == true && observed[:connected] == true && observed[:hands].is_a?(Array) &&
               observed[:hands].length == 2 && observed[:hands].all? { |id| id.nil? || id.to_s.match?(/\A[1-9]\d*\z/) }
          raise Invalid, 'controller must start alive, standing, equipped and stable in its registered refuge'
        end
        observed
      end

      def record(event)
        @objective.observe(event)
        observation = { sequence: @observation_sequence = @observation_sequence.to_i + 1,
                        type: event.type.to_s, at: event.at.to_f,
                        data: scalar_data(event.data) }.freeze
        @mutex.synchronize do
          @observations << observation
          @observations.shift while @observations.length > OBSERVATION_CAPACITY
        end
        cache_status
      rescue StandardError
        nil
      end

      def scalar_data(data)
        Hash(data).each_with_object({}) do |(key, value), result|
          result[key.to_s] = case value
                             when String, Numeric, true, false, nil then value
                             else value.to_s
                             end
        end.freeze
      end

      def cache_status
        engine_status = @engine.status
        observed = @snapshot.call rescue {}
        value = {
          mode: 'hunt', state: @state, reason: @reason,
          behavior: engine_status[:behavior], room_id: observed[:room_id],
          retreat_pending: @phase == 'returning', control_error: @control_error,
          work_result: @work_result,
          objective: @objective.status,
          refuge: { room_id: @launch.refuge_room, phase: @phase,
                    returned: @refuge_returned == true, equipment_restored: @equipment_restored == true },
          observations: @mutex.synchronize { @observations.dup },
          timing: { updated_at: @clock.call, work_deadline: @launch.work_deadline,
                    cleanup_deadline: @launch.cleanup_deadline, return_deadline: @launch.return_deadline }
        }
        frozen = Immutable.copy(value)
        @mutex.synchronize { @cached_status = frozen }
        frozen
      end

      def assert_owner_thread!
        raise ThreadError, 'controller lifecycle must run on the eohunter owner thread' unless Thread.current.equal?(@thread)
      end
    end
  end
end
