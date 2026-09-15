# frozen_string_literal: true

# ============================================================================
# wander (bigshot's bs_wander, the hunting area, the claim, hide)
# ============================================================================

#
# bigshot's bs_wander is the loop between fights: on arriving, give
# the room wander_wait seconds to show a creature if the room is ours, and
# hand any valid one to the attack loop; otherwise drop to the wander
# stance, hide when sneaking, and step to the next room by bs_move, or go2
# the hunting room when outside the area (BSAreaRooms, 620). The engine's
# Wander is that as a behavior at the bottom of the priority list: Engage
# outranks it while there is something to fight, so wants_control? is
# simply "there is nothing to fight here", and tick is one wait, one
# stance, one hide, or one step. Rules and bigshot line references in
# hunting-engine-plan.md, "Wander".
#
module EO::Engine
  # The loop between fights: the hunting area, the claim, the walker and
  # the hide, from bigshot's bs_wander.
  module Wander
    # hunting_room / hunting_boundaries / wander_wait / sneaky_sneaky /
    # ignore_disks / wander_stance from the profile.
    Policy = Struct.new(:hunting_room, :boundaries, :wander_wait, :sneaky, :ignore_disks, :wander_stance, keyword_init: true) do
      def initialize(hunting_room: nil, boundaries: [], wander_wait: 0.3, sneaky: false, ignore_disks: false, wander_stance: nil) = super

      # The boundary room ids as Integers.
      #
      # @return [Array<Integer>]
      def boundary_ids = Array(boundaries).map(&:to_i)
    end

    # The hunting area, bigshot's BSAreaRooms: every room reachable
    # from the hunting room through passable exits without crossing a
    # boundary. More than CAP rooms means a boundary is missing; bigshot
    # prints the first location changes and exits, the engine reports
    # too_big? and lets the script decide.
    #
    # @bigshot BSAreaRooms
    class Area
      # Rooms beyond which a boundary is assumed missing.
      CAP = 200

      # The hunting room's id.
      #
      # @return [Integer]
      attr_reader :start
      # Every room in the area once built, nil before.
      #
      # @return [Array<Integer>, nil]
      attr_reader :rooms
      # The first three location changes met while building, each
      # `{ id:, location: }`, for the script's report.
      #
      # @return [Array<Hash>]
      attr_reader :location_changes

      # @param start [#to_i] the hunting room id
      # @param boundaries [Array<#to_i>] room ids the area never crosses
      # @param cap [Integer] the room count that means too big
      def initialize(start:, boundaries: [], cap: CAP)
        @start = start.to_i
        @boundaries = Array(boundaries).map(&:to_i)
        @cap = cap
        @rooms = nil
        @too_big = false
        @location_changes = []
      end

      # Walk the map breadth-first from the hunting room, stopping at
      # boundaries, and at the cap with too_big? set.
      #
      # @param world [World] answers exits_from and room_location
      # @return [Area] self
      def build(world)
        rooms = [@start]
        frontier = [@start]
        seen = { @start => true }
        last_location = location_of(world, @start)
        until frontier.empty?
          next_frontier = []
          frontier.each do |id|
            world.exits_from(id).each_key do |dest|
              next if @boundaries.include?(dest) || seen[dest]

              seen[dest] = true
              next_frontier << dest
              loc = location_of(world, dest)
              if loc && loc != last_location
                last_location = loc
                @location_changes << { id: dest, location: loc } if @location_changes.size < 3
              end
            end
          end
          rooms.concat(next_frontier)
          frontier = next_frontier
          if rooms.size >= @cap
            @too_big = true
            break
          end
        end
        @rooms = rooms
        self
      end

      # build has run.
      #
      # @return [Boolean]
      def built? = !@rooms.nil?

      # The build hit the cap: a boundary is probably missing.
      #
      # @return [Boolean]
      def too_big? = @too_big

      # The room is in the built area; false before a build.
      #
      # @param id [#to_i] a room id
      # @return [Boolean]
      def include?(id) = built? && @rooms.include?(id.to_i)

      private

      def location_of(world, id)
        world.respond_to?(:room_location) ? world.room_location(id) : nil
      end
    end

    # The wander decisions, pure: is the room ours, is there a fight here.
    module Predicates
      module_function

      # bigshot bigclaim?: the room is ours when Claim says so and
      # every disk here is the group's, unless the profile ignores disks.
      # Quick mode and a follower always say yes; both are the script's.
      #
      # @bigshot bigclaim?
      # @param world [World] answers claim_mine? and foreign_disks
      # @param policy [Wander::Policy]
      # @return [Boolean]
      def claim_ours?(world, policy)
        return false unless world.claim_mine?

        policy.ignore_disks || world.foreign_disks.empty?
      end

      # Something to fight here: the room is ours and a wanted, fightable
      # creature is on the target list (bs_wander 7575-7577).
      #
      # @bigshot bs_wander
      # @param world [World]
      # @param targets_policy [Targets::Policy]
      # @param policy [Wander::Policy]
      # @return [Boolean]
      def fight_here?(world, targets_policy, policy)
        claim_ours?(world, policy) && Targets.candidates(world.room.targets, targets_policy).any?
      end
    end
  end

  # The engine's actions: one command to the game, confirmed on its answer.
  module Actions
    # HIDE until hidden, a few tries (bigshot cmd_hide 5121: up to
    # +attempts+ sends, stopping on a flee). The stance drop bigshot does
    # first is the caller's.
    #
    # @bigshot cmd_hide
    class Hide < Base
      # Sends before giving up, when the caller names no count.
      ATTEMPTS = 3

      # @param world [World]
      # @param attempts [Integer] HIDE sends before giving up
      # @param timeout [Numeric] seconds to watch for hidden after each send
      # @param opts [Hash] passed through to Base
      def initialize(world, attempts: ATTEMPTS, timeout: 2, **opts)
        super(world, **opts)
        @attempts = attempts
        @timeout = timeout
      end

      # Dead, muckled, already hidden, or legs too hurt to sneak refuses
      # the hide.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :already_hidden if me.hidden?
        return :too_injured unless me.able_to_sneak? # Lich's Injured: legs and feet

        :ok
      end

      # Send HIDE and watch for hidden, up to the attempt count.
      #
      # @return [Actions::Result] success once hidden; the send's own failure;
      #   failed with :interrupted; or timeout with :not_hidden
      def perform
        result = nil
        @attempts.times do
          result = send_and_observe('hide', timeout: @timeout) { me.hidden? }
          return result if result.success? || result.status == :failed
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :timeout, reason: :not_hidden)
      end
    end
  end

  # The engine's behaviors, each a priority and a tick.
  module Behaviors
    # One wait, stance, hide or step per tick between fights.
    #
    # @bigshot bs_wander
    class Wander < Behavior
      # When we entered the current room, by the behavior's clock.
      #
      # @return [Time, nil]
      attr_reader :arrived_at

      # @param policy [Wander::Policy]
      # @param targets_policy [Targets::Policy]
      # @param walker [Wander::Walker] shared with Flee
      # @param area [Wander::Area, nil] built by the script; nil never sends home
      # @param travel [#call] (room) -> Trip or Boolean; default a Travel trip
      # @param stance [#call] (name) -> Boolean; default Lich::Gemstone::Stance.change
      # @param tracking [Tracking::Policy] bandit mode and the Ranger's quarry
      # @param state [Engage::State] shared with Engage for the combat-blocked room
      # @param movement [Group::Leader, nil] explicit strict group movement owner
      # @param clock [#now] the time source, injectable for specs
      def initialize(policy:, targets_policy:, walker: nil, area: nil, travel: nil, stance: nil, tracking: nil,
                     state: EO::Engine::Engage::State.new, movement: nil, clock: Time)
        super()
        @policy = policy
        @targets_policy = targets_policy
        @walker = walker || EO::Engine::Wander::Walker.new(boundaries: policy.boundary_ids)
        @area = area
        @travel = travel || EO::Engine::Travel.default
        @trip = nil
        @stance = stance || ->(name) { ::Lich::Gemstone::Stance.change(name) }
        @tracking = tracking || EO::Engine::Tracking::Policy.new
        @state = state
        @movement = movement
        @clock = clock
        @entered_room = nil
        @arrived_at = nil
        @stanced = false
        @tracked = false
        @uncovered = false
        @hidden_seen = []
        @hidden_at = nil
        @room_target_ids = []
        @departed_target_ids = []
      end

      # BanditPatrol: seconds to wait for the ambush after a hidden id
      # appears on the combat dialog.
      AMBUSH_HOLD = 5

      # The bottom of the list: every other behavior outranks the walk.
      #
      # @return [Integer] 60
      def priority = 60

      # A walk steps through rooms faster than the engine's fire budget.
      #
      # @return [nil] no budget
      def fire_budget = nil

      # The engine's stop: end a trip home in flight.
      #
      # @return [void]
      def cancel! = EO::Engine::Travel.cancel(self)

      # Another behavior took control: hold the trip home until it is ours again.
      #
      # @param _world [World] unused
      # @return [void]
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # Nothing to fight here, or combat is blocked in this room.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        note_room(world)
        return true if combat_blocked_here?(world)

        !EO::Engine::Wander::Predicates.fight_here?(world, @targets_policy, @policy)
      end

      # One thing per tick: leave a combat-blocked room, wait out
      # wander_wait, drop stance, hide, track, hold for a hidden arrival,
      # uncover, step the trip home, or step to the next room.
      #
      # @param world [World]
      # @return [Actions::Result, nil] nil while waiting or while a trip home
      #   is underway; otherwise the action's result, or failed with :no_exit
      #   or :could_not_reach, or success with :returned_home
      def tick(world)
        note_room(world)
        if combat_blocked_here?(world)
          @stance.call(@policy.wander_stance) if @policy.wander_stance
          step = @walker.next_step(world)
          return Actions::Result.new(status: :failed, reason: :no_exit) if step.nil?

          Events.emit(:combat_blocked_departure, room: world.room.id)
          return move_step(world, step.last)
        end

        # bigshot sleeps wander_wait after the first look and looks again;
        # here Engage takes over the moment a creature shows, so the wait
        # is simply time in the room before leaving it. Only in a room
        # that is ours: a claimed room is left at once.
        return nil if ours?(world) && @clock.now - @arrived_at < @policy.wander_wait.to_f

        unless @stanced
          @stanced = true
          @stance.call(@policy.wander_stance) if @policy.wander_stance
        end

        if @policy.sneaky && !world.me.hidden?
          hide = Actions::Hide.new(world).call
          # A HIDE the game refused is worth a tick: try again before
          # stepping, since the point of sneaky is not to be seen. A hide
          # the action declined (:too_injured legs, already hidden, a
          # stun) never reaches the game and will keep declining, so
          # holding on it would stop the hunter here for good; bigshot
          # sends the HIDE and walks on regardless.
          return hide if hide.failed?
        end

        # bs_wander 9427: a Ranger tracks the quarry before stepping; a
        # trail or a hidden quarry in our room holds us here.
        if @tracking.tracking? && !@tracked && !@trip
          @tracked = true
          tracked = track(world)
          return tracked if tracked
        end

        # Something is here and hidden: Lich's Overwatch saw a creature
        # hide, or the combat dialog lists an id no room object answers to
        # (GameObj.hidden_targets: a bandit arrives hidden and is announced
        # there before it attacks). An empty target list is not an empty
        # room. BanditPatrol's rule: hold AMBUSH_HOLD after each new hidden
        # id for the ambush that reveals it, then one uncover per room
        # before leaving. A reveal is Engage's next tick; a creature that
        # stays hidden does not hold the wander.
        if !@trip && ours?(world) && world.room.targets.empty?
          hidden = current_hidden_target_ids(world)
          arrived = hidden - @hidden_seen
          unless arrived.empty?
            @hidden_seen.concat(arrived)
            @hidden_at = @clock.now
            Events.emit(:hidden_arrival, room: world.room.id, ids: arrived)
          end
          return nil if @hidden_at && @clock.now - @hidden_at < AMBUSH_HOLD

          if !@uncovered && (world.hiders? || hidden.any?)
            @uncovered = true
            result = Actions::Uncover.new(world).call
            Events.emit(:uncovered, room: world.room.id, reason: result.reason)
            return result
          end
        end

        if @trip || (@area&.built? && !@area.include?(world.room.id))
          if @movement&.strict_movement?
            Events.emit(:coordination_return_required, reason: :out_of_bounds, room: world.room.id)
            return Actions::Result.new(status: :skipped, reason: :coordination_return_required)
          end
          Events.emit(:out_of_bounds, room: world.room.id, hunting_room: @policy.hunting_room) if @trip.nil?
          case EO::Engine::Travel.step(self, @travel, @policy.hunting_room, world)
          when :underway then return nil
          when :arrived then return Actions::Result.new(status: :success, reason: :returned_home)
          else return Actions::Result.new(status: :failed, reason: :could_not_reach)
          end
        end

        step = @walker.next_step(world)
        return Actions::Result.new(status: :failed, reason: :no_exit) if step.nil?

        move_step(world, step.last)
      end

      private

      def move_step(world, way)
        return Actions::Move.new(world, way: way).call unless @movement&.strict_movement?

        result = Actions::GroupMove.new(world, way: way, leader: @movement).call
        if %i[unsupported_group_exit unsupported_movement_guard].include?(result.reason)
          Events.emit(:coordination_return_required, reason: result.reason, room: world.room.id)
        end
        result
      end

      # nil == nil read as blocked in an unmapped room; see engage.rb.
      def combat_blocked_here?(world)
        @state.combat_blocked_room && @state.combat_blocked_room.to_s == world.room.id.to_s
      end

      def ours?(world) = EO::Engine::Wander::Predicates.claim_ours?(world, @policy)

      # ranger_track 9500-9512: a Result to return when the track holds us
      # in place (uncovering when nothing hostile shows), nil to move on.
      def track(world)
        result = Actions::Track.new(world, creature: @tracking.creature_name).call
        case result.reason
        when :trail
          Actions::Uncover.new(world).call if world.room.targets.empty?
          Events.emit(:tracked, creature: @tracking.creature_name, outcome: :trail, room: world.room.id)
          Actions::Result.new(status: :success, reason: :tracked)
        when :here
          return nil unless ours?(world)

          Actions::Uncover.new(world).call if world.room.targets.empty?
          Events.emit(:tracked, creature: @tracking.creature_name, outcome: :here, room: world.room.id)
          Actions::Result.new(status: :success, reason: :tracked)
        end
      end

      def note_room(world)
        id = world.room.id
        visible = Array(world.room.targets).filter_map { |target| target.id.to_s unless target.id.nil? }
        if id == @entered_room
          @room_target_ids |= visible
          return
        end

        @departed_target_ids |= @room_target_ids
        @room_target_ids = visible

        @entered_room = id
        @arrived_at = @clock.now
        @stanced = false
        @tracked = false
        @uncovered = false
        @hidden_seen = []
        @hidden_at = nil
      end

      # The combat dialog can retain a target after we leave its room (for
      # example while a damage-over-time spell keeps ticking). GameObj then
      # reports that absent id as a hidden target. Keep ids actually seen in
      # prior rooms quarantined until the dialog drops them; a genuinely new
      # hidden arrival remains eligible for the ordinary ambush hold.
      def current_hidden_target_ids(world)
        hidden = Array(world.hidden_target_ids).map(&:to_s)
        @departed_target_ids &= hidden
        hidden - @departed_target_ids
      end
    end
  end
end
