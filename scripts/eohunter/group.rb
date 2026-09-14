# frozen_string_literal: true

# ============================================================================
# group (bigshot's head/tail: Bigshot::Group over DRb, Event, the follower
#        loop, and every follower wait in the leader's hunt and rest)
# ============================================================================

#
# bigshot's group is a Bigshot::Group object the leader serves over DRb
# (9882); each follower registers its own Bigshot instance in it
# and the leader calls those instances directly for every question
# (ready_to_hunt?, looting_inactive?, rt? ...) and pushes Events onto
# their stacks (add_event 1061), which the follower loop works
# through one at a time. The engine keeps the shape and turns the calls
# around: the leader serves a Hub, followers push a Report into it every
# tick and pull their Orders from it, so the leader never makes a remote
# call and a follower that stops reporting is seen as lost instead of
# raising into the leader's loop. A follower's every call to the Hub is
# bounded, and a Hub that stops answering (the leader's Lich is gone) is
# a lost leader. Every order and every ack carries the hunt id.
#
#   Hub      the protocol object: roster, readiness, orders, reports, acks
#   Leader   the leader's view of the Hub: the group waits bigshot makes
#   Member   the follower's link to a Hub, remote calls bounded
#   Orders   the follower's Rest: the leader's orders, one step per tick
#   Assist   the follower's Engage: the leader's target first
#   Follow   the follower's Wander: back to the leader, join the group
#   Muster   the leader's holds between fights
#
# Rules and bigshot line references in hunting-engine-plan.md, "Group".
#
module EO::Engine
  # The group protocol and the behaviors on both sides of it: the Hub the
  # leader serves, the Leader and Member views of it, and the Report and
  # Order records that cross it. Every remote call goes follower to leader.
  module Group
    # The MA Grouping settings from the profile.
    #
    # @bigshot MA Grouping
    # @!attribute independent_travel
    #   @return [Boolean] followers travel to the hunting room on their own
    # @!attribute independent_return
    #   @return [Boolean] followers travel back to rest on their own
    # @!attribute group_deader
    #   @return [Boolean] the group runs a deader for a fallen member
    # @!attribute looter
    #   @return [String, nil] the named looter, matched case-insensitively
    # @!attribute quiet_followers
    #   @return [Boolean] followers keep their output quiet
    # @!attribute never_loot
    #   @return [Array<String>] names that never loot
    # @!attribute random_loot
    #   @return [Boolean] the least encumbered member loots
    # @!attribute fried_trigger
    #   @return [Array<String>] "any", "all", or the names whose frying rests the group
    Policy = Struct.new(:independent_travel, :independent_return, :group_deader, :looter, :quiet_followers,
                        :never_loot, :random_loot, :fried_trigger, keyword_init: true) do
      def initialize(independent_travel: false, independent_return: false, group_deader: false, looter: nil,
                     quiet_followers: true, never_loot: [], random_loot: false, fried_trigger: ['any']) = super

      # The never_loot setting as strings, whatever the profile gave.
      #
      # @return [Array<String>] the names that never loot
      def never_loot_list = Array(never_loot).map(&:to_s)

      # Whether the currently fried members satisfy the configured group
      # trigger. The profile accepts "any", "all", or one or more names.
      #
      # @param fried_names [Array<String>] the members reporting fried
      # @param active_names [Array<String>] the members with fresh reports, plus the leader
      # @return [Boolean] true when the trigger is met
      def fried_rest?(fried_names, active_names:)
        trigger = Array(fried_trigger).flat_map { |value| value.to_s.split(',') }
                                      .map { |value| value.strip.downcase }
                                      .reject(&:empty?)
        fried = Array(fried_names).map { |name| name.to_s.downcase }
        active = Array(active_names).map { |name| name.to_s.downcase }

        return fried.any? if trigger.empty? || trigger.include?('any')
        return (active - fried).empty? if trigger.include?('all')

        !(trigger & fried).empty?
      end
    end

    # bigshot's Event types, by their engine names.
    #
    # @bigshot Event types
    ORDERS = %i[
      attack follow_now prepare_move hunting_prep hunting_scripts_start hunting_scripts_stop cast_signs check_sneaky
      go2_rally go2_hunting_room prep_rest leave_group fog_return go2_waypoints go2_resting_room
      resting_prep resting_scripts_start loot unhide follower_overkill hunt_over command
    ].freeze

    # One instruction from the leader (Event 763): raised in a room at a
    # time, for one hunt. An attack order from another room or older than
    # 15 s is stale. This is the 15, in seconds.
    #
    # @bigshot Event, stale attack
    STALE_AFTER = 15

    # The instruction itself, one per order: its type (one of ORDERS), the
    # hunt it belongs to, the room it was raised in, when, and a payload.
    #
    # @!attribute type
    #   @return [Symbol] one of ORDERS
    # @!attribute hunt_id
    #   @return [String] the open hunt's id
    # @!attribute room
    #   @return [Integer, nil] the leader's room when raised
    # @!attribute at
    #   @return [Time] when the order was raised
    # @!attribute payload
    #   @return [Object, nil] the order's argument (a reason, a name, a command)
    Order = Struct.new(:type, :hunt_id, :room, :at, :payload, keyword_init: true) do
      # Whether this order is too old or from another room to act on.
      #
      # @param room_now [Integer] the follower's current room
      # @param now [Time] the clock to age against
      # @return [Boolean] true when from another room or older than STALE_AFTER
      def stale?(room_now, now = Time.now)
        room != room_now || (now.to_f - at.to_f) > Group::STALE_AFTER
      end
    end

    # What a follower tells the leader every tick: the answers bigshot's
    # leader asks each member for (ready_to_rest? 8977, ready_to_hunt?
    # 8917, rt? 8732, looting_inactive? 9261, rest_prep_done? 8737,
    # encumbrance? 8768, sneaky_hunt? 8763, player_hidden? 8758).
    #
    # @bigshot ready_to_rest?, ready_to_hunt?, rt?, looting_inactive?,
    #   rest_prep_done?, encumbrance?, sneaky_hunt?, player_hidden?
    # @!attribute name
    #   @return [String] the follower's name
    # @!attribute room
    #   @return [Integer] the follower's room id
    # @!attribute rt
    #   @return [Boolean] in hard or cast roundtime
    # @!attribute hidden
    #   @return [Boolean] hidden right now
    # @!attribute sneaky
    #   @return [Boolean] the follower's sneaky_sneaky setting
    # @!attribute looting
    #   @return [Boolean] still looting
    # @!attribute rest_prep_done
    #   @return [Boolean] the resting prep lists have run
    # @!attribute rest_reason
    #   @return [String, nil] why the follower wants to rest, or nil
    # @!attribute not_hunting_reason
    #   @return [String, nil] why the follower is not ready to hunt, or nil
    # @!attribute encumbrance_left
    #   @return [Integer] encumbrance percent still free under the rest floor
    # @!attribute wounded
    #   @return [Boolean] the rest policy's wounded check answered true
    # @!attribute bounty
    #   @return [Symbol, nil] :none, :hunting, :complete or :failed
    # @!attribute at
    #   @return [Time, nil] when the report was made; the Hub stamps a nil
    Report = Struct.new(:name, :room, :rt, :hidden, :sneaky, :looting, :rest_prep_done, :rest_reason,
                        :not_hunting_reason, :encumbrance_left, :wounded, :bounty, :at, keyword_init: true)

    # A member's bounty state for the report (the split plan's 3.1), from
    # Lich's Bounty task: :none, :hunting, :complete or :failed.
    #
    # @param world [World] answers bounty_task
    # @return [Symbol] :none, :hunting, :complete or :failed
    def self.bounty_state(world)
      task = world.bounty_task
      return :none if task.nil? || task.none?
      return :failed if task.type == :failed
      return :complete if task.done?

      :hunting
    end

    # The Report for this tick, from the follower's own policies.
    #
    # @param world [World] the follower's world
    # @param name [String] the follower's name
    # @param rest_policy [Rest::Policy] the follower's rest settings
    # @param counters [Rest::Counters] the follower's rest counters
    # @param sneaky [Boolean] the follower's sneaky_sneaky
    # @param looting [Boolean] still looting
    # @param rest_prep_done [Boolean] the resting prep lists have run
    # @param bounty [Symbol, nil] :none, :hunting, :complete or :failed
    # @param forced [String, nil] a rest the follower's own events asked for
    #   (Rest#rest!: no fresh wands, ammo with no effect, a stuck maintain),
    #   reported ahead of the threshold reasons so the leader brings the
    #   group home instead of hunting on while the follower keeps failing
    # @param now [Time] the report's timestamp
    # @param encumbrance [Rest::Encumbrance, nil] persistent follower weight filter
    # @return [Report] the filled report
    def self.report(world, name:, rest_policy:, counters:, sneaky: false, looting: false, rest_prep_done: false, bounty: nil, forced: nil, now: Time.now,
                    encumbrance: nil)
      me = world.me
      overweight = encumbrance&.ready?(me.encumbrance_pct, threshold: rest_policy.encumbered_pct, looting: looting)
      Report.new(
        name: name, room: world.room.id, rt: me.in_rt? || me.in_cast_rt?, hidden: me.hidden?, sneaky: sneaky,
        looting: looting, rest_prep_done: rest_prep_done,
        rest_reason: Rest::Predicates.rest_reason(me, rest_policy, counters, forced: forced, looting: looting, encumbered: overweight),
        not_hunting_reason: Rest::Predicates.not_hunting_reason(me, rest_policy),
        encumbrance_left: rest_policy.encumbered_pct - me.encumbrance_pct.to_i,
        wounded: rest_policy.wounded ? (rest_policy.wounded.call ? true : false) : false,
        bounty: bounty, at: now
      )
    end

    # The protocol object. Served over DRb by the leader; every method is
    # safe to call from any thread. No game state: pure Ruby.
    class Hub
      include ::DRbUndumped if defined?(::DRbUndumped)

      # Seconds a follower may be silent before it is offline.
      REPORT_STALE = 10 # a follower silent this long is offline
      # Seconds the leader may be silent before it is lost.
      HEARTBEAT_STALE = 15 # a leader silent this long is lost
      # Seconds between liveness pulses, well inside both stale limits.
      PULSE = 3 # the liveness pulse, well inside both

      # @!attribute [r] hunt_id
      #   @return [String, nil] the open hunt's id, nil before open_hunt
      # @!attribute [r] leader_name
      #   @return [String, nil] the leader's name
      # @!attribute [r] expected
      #   @return [Integer, Array<String>] the roster: a count, or the names
      # @!attribute [r] rooms
      #   @return [Hash] the leader's :rally, :hunting, :waypoints, :resting rooms
      # @!attribute [r] last_exit
      #   @return [Hash, nil] the record of how the last hunt ended
      attr_reader :hunt_id, :leader_name, :expected, :rooms, :last_exit

      # @param clock [#now] the time source, Time in the game
      def initialize(clock: Time)
        @clock = clock
        @mutex = Mutex.new
        @hunt_id = nil
        @leader_name = nil
        @expected = []
        @rooms = {}
        @members = {}
        @queues = {}
        @reports = {}
        @acks = {}
        @active = false
        @leader_state = {}
        @heartbeat = nil
        @finished = nil
        @last_exit = nil
      end

      # --- the leader --------------------------------------------------------

      # A new hunt: a fresh id, the roster it expects (a count, or the
      # names), the leader's rooms for the followers' own trips.
      #
      # @param leader [String] the leader's name
      # @param expected [Integer, Array<String>]
      # @param rooms [Hash] :rally, :hunting, :waypoints, :resting
      # @return [String] the new hunt id
      def open_hunt(leader:, expected:, rooms: {})
        @mutex.synchronize do
          @hunt_id = format('%08x', rand(2**32))
          @leader_name = leader.to_s
          @expected = expected.is_a?(Integer) ? expected : Array(expected).map(&:to_s)
          @rooms = rooms
          @members = {}
          @queues = {}
          @reports = {}
          @acks = {}
          @active = false
          @leader_state = {}
          @heartbeat = @clock.now
          @finished = nil
          @last_exit = nil
          @hunt_id
        end
      end

      # @return [Boolean] true once open_hunt has run
      def open? = !@hunt_id.nil?

      # @return [Array<String>] the registered followers' names
      def members = @mutex.synchronize { @members.keys }

      # bigshot's rally wait: every expected follower has registered.
      #
      # @bigshot rally wait
      # @return [Boolean] true when the roster is full
      def ready?
        @mutex.synchronize do
          @expected.is_a?(Integer) ? @members.size >= @expected : (@expected - @members.keys).empty?
        end
      end

      # Who has not registered yet: the names, or "N more" for a count.
      #
      # @return [Array<String>] the missing names, or one "N more" entry
      def missing
        @mutex.synchronize do
          @expected.is_a?(Integer) ? ["#{[@expected - @members.size, 0].max} more"] : @expected - @members.keys
        end
      end

      # Mark the hunt active: the roster is in and the leader has started.
      #
      # @return [Boolean] true
      def activate! = @mutex.synchronize { @active = true }
      # @return [Boolean] true after activate!
      def active? = @active

      # The leader's state, every tick: room, target, phase, looter.
      #
      # @param state [Hash] the leader's published state
      # @return [Boolean] true
      def heartbeat!(state = {})
        @mutex.synchronize do
          @leader_state = state
          @heartbeat = @clock.now
        end
        true
      end

      # @return [Hash] a copy of the leader's last published state
      def leader_state = @mutex.synchronize { @leader_state.dup }

      # Whether the leader is still heartbeating and has not finished.
      #
      # @param now [Time] the clock to age the heartbeat against
      # @return [Boolean] true while the last heartbeat is inside HEARTBEAT_STALE
      def leader_alive?(now = @clock.now)
        @mutex.synchronize { @finished.nil? && !@heartbeat.nil? && (now.to_f - @heartbeat.to_f) < HEARTBEAT_STALE }
      end

      # Record that the leader is done; leader_alive? is false from here.
      #
      # @param reason [Symbol, String] why the hunt ended
      # @return [Symbol, String] the reason
      def leader_finished!(reason)
        @mutex.synchronize { @finished = reason }
        reason
      end

      # @return [Symbol, String, nil] the reason from leader_finished!, or nil
      def finished_reason = @finished

      # An order to every registered follower (add_event 1061).
      #
      # @bigshot add_event
      # @param type [Symbol] one of ORDERS
      # @param payload [Object, nil] the order's argument
      # @param room [Integer, nil] the room the order is raised in
      # @return [Order] the order queued
      # @raise [ArgumentError] for a type not in ORDERS
      def broadcast(type, payload = nil, room: nil)
        order = make_order(type, payload, room)
        @mutex.synchronize do
          @queues.each_value { |q| q << order }
          # The follower clears its own rest_prep_done when it processes the
          # order, which is at least a tick away and may be several. The
          # leader queues :resting_prep and tests rest_prep_complete? in the
          # same call, so on every rest after the first it read last cycle's
          # true and the barrier passed before any follower had prepped.
          # Clearing here means the flag is false from the moment the order
          # exists, and only a fresh report can set it again.
          @reports.each_value { |r| r.rest_prep_done = false if r.respond_to?(:rest_prep_done=) } if type == :resting_prep
        end
        order
      end

      # An order to one follower.
      #
      # @param name [String] the follower's name
      # @param type [Symbol] one of ORDERS
      # @param payload [Object, nil] the order's argument
      # @param room [Integer, nil] the room the order is raised in
      # @return [Order] the order queued
      # @raise [ArgumentError] for a type not in ORDERS
      def order(name, type, payload = nil, room: nil)
        order = make_order(type, payload, room)
        @mutex.synchronize { (@queues[name.to_s] ||= []) << order }
        order
      end

      # Whether an order of this type is still queued for the follower.
      #
      # @param name [String] the follower's name
      # @param type [Symbol] the order type
      # @return [Boolean] true while one waits in the queue
      def pending?(name, type) = @mutex.synchronize { Array(@queues[name.to_s]).any? { |o| o.type == type } }

      # @return [Hash{String => Report}] a copy of the last report per follower
      def reports = @mutex.synchronize { @reports.dup }

      # Who is answering: by the age of the last report.
      #
      # @param now [Time] the clock to age the reports against
      # @return [Hash{String => Symbol}] :online or :offline per registered follower
      def liveness(now = @clock.now)
        @mutex.synchronize do
          @members.keys.to_h do |name|
            report = @reports[name]
            last_seen = report&.at || @members[name]
            [name, last_seen && (now.to_f - last_seen.to_f) < REPORT_STALE ? :online : :offline]
          end
        end
      end

      # Who has acknowledged an order type since the last clear.
      #
      # @param type [Symbol] the order type
      # @return [Array<String>] the follower names that acked it
      def acked(type) = @mutex.synchronize { (@acks[type] || {}).keys }

      # Forget the acks for an order type, before it is sent again.
      #
      # @param type [Symbol] the order type
      # @return [Hash] the empty ack table
      def clear_acks(type) = @mutex.synchronize { @acks[type] = {} }

      # Store the record of how the hunt ended.
      #
      # @param record [Hash] reason, hunt_id, at, and for end_hunt the acks
      # @return [Hash] the record
      def last_exit=(record)
        @mutex.synchronize { @last_exit = record }
      end

      # --- the follower --------------------------------------------------------

      # Join this hunt (add_member 998). The id must be the open hunt's;
      # a name the roster does not expect is refused.
      #
      # @bigshot add_member
      # @param name [String] the follower's name
      # @param hunt_id [String] the id the follower read from hunt_id
      # @return [String] the hunt id
      # @raise [ArgumentError] when the id is not the open hunt's, or the name is not expected
      def register(name, hunt_id:)
        @mutex.synchronize do
          raise ArgumentError, "hunt #{hunt_id} is not open" unless hunt_id == @hunt_id
          raise ArgumentError, "#{name} is not expected" unless @expected.is_a?(Integer) || @expected.include?(name.to_s)

          # Registration is a bounded first-report grace period. Without
          # it, the leader can declare a follower lost in the interval
          # between a successful join and that follower's first tick.
          @members[name.to_s] = @clock.now
          @queues[name.to_s] ||= []
          @hunt_id
        end
      end

      # File a follower's report; the leader's state rides back on the answer.
      #
      # @param name [String] the follower's name
      # @param report [Report] this tick's report; a nil +at+ is stamped now
      # @return [Hash] a copy of the leader's last published state
      def report(name, report)
        report.at ||= @clock.now
        @mutex.synchronize do
          @reports[name.to_s] = report
          @leader_state.dup
        end
      end

      # Every order queued for this follower, oldest first, the queue emptied.
      #
      # @param name [String] the follower's name
      # @return [Array<Order>] the orders taken, empty when none or unregistered
      def take_orders(name)
        @mutex.synchronize do
          queue = @queues[name.to_s]
          return [] unless queue

          taken = queue.dup
          queue.clear
          taken
        end
      end

      # Acknowledge an order type for this hunt.
      #
      # @param type [Symbol] the order type
      # @param name [String] the follower's name
      # @param hunt_id [String] the follower's hunt id
      # @return [Boolean] true
      # @raise [ArgumentError] when the id is not the open hunt's
      def ack(type, name, hunt_id:)
        @mutex.synchronize do
          raise ArgumentError, "hunt #{hunt_id} is not open" unless hunt_id == @hunt_id

          (@acks[type] ||= {})[name.to_s] = true
        end
      end

      private

      def make_order(type, payload, room)
        raise ArgumentError, "unknown order #{type}" unless ORDERS.include?(type)

        Order.new(type: type, hunt_id: @hunt_id, room: room, at: @clock.now, payload: payload)
      end
    end

    # The leader's view: what bigshot's leader asks its Group, answered
    # from the followers' reports. Followers that have stopped reporting
    # are left out of every wait (member_online 966 drops them; here
    # they are reported lost once and waited on no more).
    class Leader
      # Seconds between keep_alive! heartbeats, the Hub's pulse.
      PULSE = Hub::PULSE

      # @!attribute [r] hub
      #   @return [Hub] the protocol object this leader serves
      # @!attribute [r] policy
      #   @return [Policy] the MA Grouping settings
      # @!attribute [r] name
      #   @return [String] the leader's own name
      attr_reader :hub, :policy, :name

      # @param hub [Hub] the protocol object, already opened or about to be
      # @param name [String] the leader's own name
      # @param policy [Policy] the MA Grouping settings
      # @param clock [#now] the time source
      def initialize(hub, name:, policy: Policy.new, clock: Time)
        @hub = hub
        @name = name.to_s
        @policy = policy
        @clock = clock
        @lost = []
      end

      # @return [String, nil] the Hub's open hunt id
      def hunt_id = @hub.hunt_id

      # Nobody has registered, so every group hold is vacuous and the
      # leader hunts as one character. This is membership, not presence: a
      # follower that registered and then went quiet still counts, which is
      # what keeps Muster waiting for it instead of wandering off alone.
      #
      # @bigshot solo?
      # @return [Boolean] true when no follower has registered
      def solo? = @hub.members.empty?

      # @return [Array<String>] every registered follower, online or not
      def followers = @hub.members

      # @return [Array<String>] the followers whose last report is fresh
      def online = @hub.liveness(@clock.now).select { |_, state| state == :online }.keys

      # Followers gone quiet since last asked; each is reported once.
      #
      # @return [Array<String>] the names newly offline since the last call
      def newly_lost
        offline = @hub.liveness(@clock.now).select { |_, state| state == :offline }.keys
        fresh = offline - @lost
        @lost = offline
        fresh
      end

      # bigshot size: followers and the leader.
      #
      # @bigshot size
      # @return [Integer] the registered followers plus one
      def size = followers.size + 1

      # Current decision quorum: followers with fresh reports and the
      # leader. An offline registration must not keep an all-member
      # readiness policy waiting forever.
      #
      # @return [Array<String>] the online followers and the leader
      def active_names = online + [@name]

      # The policy's fried trigger against the current quorum.
      #
      # @param names [Array<String>] the members reporting fried
      # @return [Boolean] true when the group should rest for frying
      def fried_rest?(names) = @policy.fried_rest?(names, active_names: active_names)

      # The leader's state for the followers, every tick.
      #
      # @param world [World] the leader's world, for the room
      # @param phase [Symbol] the leader's phase (:hunting, :resting, ...)
      # @param target [#id, #name, #noun, nil] the leader's current target
      # @return [Boolean] true, from the Hub's heartbeat!
      # @param signs [Boolean] the leader is at the hunting room or hunting
      #   from it, where signs belong; false for the rest of the cycle
      def publish(world, phase:, target: nil, signs: true)
        @last_state = {
          name: @name, room: world.room.id, phase: phase, looter: @looter, signs: signs,
          target: target && { id: target.id.to_s, name: target.name.to_s, noun: target.noun.to_s }
        }
        @hub.heartbeat!(@last_state)
      end

      # Liveness apart from the tick: an action that blocks longer than
      # HEARTBEAT_STALE (a sleep in a command list, a long roundtime, a
      # recovery) must not read as a dead leader to the followers. The
      # pulse repeats the last published state until stopped; the
      # engine's own watchdog is what notices stalled work.
      #
      # @param interval [Numeric] seconds between heartbeats
      # @return [Thread] the pulse thread
      def keep_alive!(interval: PULSE)
        stop_pulse!
        @pulse = Thread.new do
          loop do
            sleep interval
            begin
              @hub.heartbeat!(@last_state) if @last_state
            rescue StandardError
              nil # one bad beat must not end the pulse: the thread dies
            end # silently, liveness stops, and stop_pulse! never notices
          end
        end
      end

      # Kill the keep_alive! pulse, if one runs.
      #
      # @return [nil]
      def stop_pulse!
        @pulse&.kill
        @pulse = nil
      end

      # An order to every follower; nothing when solo.
      #
      # @param type [Symbol] one of ORDERS
      # @param payload [Object, nil] the order's argument
      # @param room [Integer, nil] the room the order is raised in
      # @return [Order, nil] the order broadcast, nil when solo
      def order(type, payload = nil, room: nil)
        return nil if solo?

        @hub.broadcast(type, payload, room: room)
      end

      # Ask every follower to stand down and ack before the group moves.
      #
      # @param room [Integer] the room the move starts from
      # @return [Order, nil] the prepare_move order, nil when solo
      def prepare_movement(room)
        @hub.clear_acks(:prepare_move)
        order(:prepare_move, room: room)
      end

      # Whether the group can move: everyone here, nobody in roundtime,
      # every online follower has acked prepare_move.
      #
      # @param world [World] the leader's world
      # @return [Boolean] true when the barrier is down
      def movement_ready?(world)
        all_present?(world) && !roundtime? && (online - @hub.acked(:prepare_move)).empty?
      end

      # @return [Hash{String => Report}] the last report of each online follower
      def reports
        live = online
        @hub.reports.select { |name, _| live.include?(name) }
      end

      # all_present?: every follower in the room and in the game's
      # group.
      #
      # @bigshot all_present?
      # @param world [World] the leader's world
      # @return [Boolean] true when every online follower is here and grouped
      def all_present?(world)
        here = Array(world.room.players).map { |p| p.noun.to_s }
        grouped = world.group_nouns
        online.all? { |n| here.include?(n) && grouped.include?(n) }
      end

      # The barriers the leader holds on, each answered from the followers'
      # own reports rather than from anything the leader can see. Only
      # online members are consulted, so a follower that has gone quiet
      # cannot hold the group forever; the cost is that one whose Lich died
      # mid-loot stops being waited for.

      # @bigshot Bigshot::Group
      # @return [Boolean] true when no online follower is still looting
      def looting_done? = reports.values.none?(&:looting)

      # Movement would be refused during roundtime anyway; the barrier
      # saves the sends anyone would otherwise burn discovering that.
      # @bigshot Bigshot::Group
      # @return [Boolean] true when any online follower is in roundtime
      def roundtime? = reports.values.any?(&:rt)

      # Every follower has run its own resting commands and scripts, which
      # is the signal the leader waits on before ending a rest.
      # @bigshot Bigshot::Group
      # @return [Boolean] true when every online follower's rest prep has run
      def rest_prep_complete? = reports.values.all?(&:rest_prep_done)

      # Moving now would leave a sneaky follower standing visible in the
      # room the group is leaving.
      # @bigshot Bigshot::Group
      # @return [Boolean] true when a sneaky follower is not yet hidden
      def need_sneaky? = reports.values.any? { |r| r.sneaky && !r.hidden }

      # One wounded follower rests the whole group: the hunt is only as
      # healthy as its worst member.
      # @bigshot Bigshot::Group
      # @return [Boolean] true when any online follower reports wounded
      def any_wounded? = reports.values.any?(&:wounded)

      # Each follower's own reason to rest, kept per member rather than
      # reduced to a boolean so the leader can say which one sent the group
      # home.
      #
      # @bigshot group_should_rest?
      # @return [Hash{String => String}] the rest reason per follower that has one
      def rest_reasons = reports.filter_map { |n, r| [n, r.rest_reason] if r.rest_reason }.to_h

      # group_should_hunt?: each follower still not ready.
      #
      # @bigshot group_should_hunt?
      # @return [Hash{String => String}] the not-hunting reason per follower that has one
      def not_hunting_reasons = reports.filter_map { |n, r| [n, r.not_hunting_reason] if r.not_hunting_reason }.to_h

      # group_encumbrance: weight still free per follower.
      #
      # @bigshot group_encumbrance
      # @return [Hash{String => Integer}] encumbrance percent still free per follower
      def encumbrance = reports.transform_values { |r| r.encumbrance_left.to_i }

      # ma_looter: the named looter when in the group; with
      # random_loot the least encumbered, the named one on a tie; else the
      # leader unless never_loot says so, else a follower at random.
      #
      # @bigshot ma_looter
      # @param me_left [Integer] the leader's own free encumbrance
      # @return [String, nil] the chosen looter's name, also published from here on
      def looter(me_left: 0)
        names = online + [@name]
        return @looter = @name if solo?

        unless @policy.looter.to_s.empty?
          # anchored: an unanchored match handed every corpse to Bobby
          # when the profile named Bo, silently looting the wrong character
          found = names.find { |n| n.to_s.casecmp(@policy.looter.to_s).zero? }
          return @looter = found if found
        end
        never = @policy.never_loot_list
        if @policy.random_loot
          weights = encumbrance.merge(@name => me_left).reject { |n, _| never.include?(n) }
          best = weights.values.max
          candidates = weights.select { |_, v| v == best }.keys
          # The named lookup above already returned whenever the configured
          # looter is on the roster, so reaching here means it is not one of
          # these candidates and there is nothing to prefer. Kept as the
          # plain random pick bigshot makes (ma_looter 7119).
          return @looter = candidates.sample if candidates.any?
        end
        eligible = names - never
        @looter = eligible.include?(@name) ? @name : eligible.sample
      end

      # The unacknowledged shutdown: hunt_over to everyone, the Hub marked
      # finished, an exit record with no ack wait. end_hunt is the one
      # that waits.
      #
      # @param reason [Symbol, String] why the hunt ended
      # @return [Hash] the exit record stored on the Hub
      def finish!(reason)
        # The unacknowledged fallback. end_hunt already broadcast, waited
        # for the acks and stored the full record; running this after it
        # would send a second hunt_over and replace that record with a
        # smaller one, losing the unacked list the report is for. The
        # leader_finished! flag is how we know it already ran.
        return @hub.last_exit if @hub.finished_reason

        @hub.broadcast(:hunt_over, reason) unless solo?
        @hub.leader_finished!(reason)
        @hub.last_exit = { reason: reason, hunt_id: hunt_id, at: @clock.now }
      end

      # --- the bounty (the split plan's 3.2 and 3.3) ------------------------

      # Each follower's bounty state from its report: :none, :hunting,
      # :complete or :failed; terminal states stick once seen.
      #
      # @return [Hash{String => Symbol}] the remembered bounty state per follower
      def bounty_states
        @bounty_states ||= {}
        reports.each { |n, r| @bounty_states[n] = r.bounty if r.bounty && !%i[complete failed].include?(@bounty_states[n]) }
        @bounty_states.dup
      end

      # Forget the remembered bounty states, at the start of a new task.
      #
      # @return [Hash] the empty table
      def reset_bounty! = @bounty_states = {}

      # Liveness first, then progress: a lost member ends the hunt before
      # anything else; complete only when every registered follower is
      # complete, failed or not on a bounty. +own+ is the leader's state.
      #
      # @param own [Symbol] the leader's own bounty state, :hunting or :complete
      # @return [Symbol] :member_lost, :hunting or :bounty_complete
      def verdict(own)
        return :member_lost if (followers - online).any?
        return :hunting if own == :hunting

        states = bounty_states
        return :hunting if followers.any? { |n| states[n].nil? || states[n] == :hunting }

        :bounty_complete
      end

      # The bounty child's decision from the verdict, so the leader's own
      # completion never rests the group while a follower is unfinished:
      # :member_lost (end the hunt), :rest (everyone is done), :hunt.
      #
      # @param own_complete [Boolean] the leader's own bounty_eval
      # @return [Symbol] :member_lost, :rest or :hunt
      def bounty_decision(own_complete)
        case verdict(own_complete ? :complete : :hunting)
        when :member_lost then :member_lost
        when :bounty_complete then :rest
        else :hunt
        end
      end

      # The acknowledged shutdown: hunt_over to everyone, a wait for the
      # acks bounded by +deadline+ seconds, and an exit record naming who
      # never answered. Unclean when anyone is missing.
      #
      # @param reason [Symbol, String] why the hunt ended
      # @param deadline [Numeric] seconds to wait for the acks
      # @return [Hash] the exit record: reason, hunt_id, at, members, unacked, clean
      def end_hunt(reason, deadline: 15)
        return finish!(reason) if solo?

        @hub.broadcast(:hunt_over, reason)
        stop_at = @clock.now + deadline
        loop do
          break if (followers - @hub.acked(:hunt_over)).empty?
          break if @clock.now >= stop_at

          sleep 0.25
        end
        unacked = followers - @hub.acked(:hunt_over)
        @hub.leader_finished!(reason)
        @hub.last_exit = { reason: reason, hunt_id: hunt_id, at: @clock.now, members: bounty_states, unacked: unacked, clean: unacked.empty? }
        Events.emit(:hunt_ended, reason: reason, unacked: unacked)
        @hub.last_exit
      end
    end

    # The follower's link to the Hub. Every call is bounded: a Hub that
    # does not answer within the deadline, or raises (the leader's Lich is
    # gone), marks the leader lost, and the caller gets the default.
    class Member
      # Seconds a remote call may take before the leader counts as lost.
      DEADLINE = 3
      # Seconds between keep_alive! reports, the Hub's pulse.
      PULSE = Hub::PULSE

      # @!attribute [r] name
      #   @return [String] the follower's own name
      # @!attribute [r] hunt_id
      #   @return [String, nil] the hunt joined, nil until register succeeds
      attr_reader :name, :hunt_id

      # @param hub [Hub] the leader's Hub, usually a DRb proxy
      # @param name [String] the follower's own name
      # @param deadline [Numeric] seconds each remote call may take
      # @param clock [#now] the time source
      def initialize(hub, name:, deadline: DEADLINE, clock: Time)
        @hub = hub
        @name = name.to_s
        @deadline = deadline
        @clock = clock
        @hunt_id = nil
        @lost = false
        @state = {}
      end

      # @return [Boolean] true once a remote call has failed or timed out
      def lost? = @lost

      # bigshot: join the open hunt; false until there is one.
      #
      # @bigshot follower join
      # @return [Boolean] true when registered
      def register
        id = remote { @hub.hunt_id }
        return false if id.nil?

        @hunt_id = remote { @hub.register(@name, hunt_id: id) }
        !@hunt_id.nil?
      end

      # @return [Boolean] true once register has succeeded
      def registered? = !@hunt_id.nil?

      # File this tick's report; the leader's state that rides back is kept.
      #
      # @param report [Report] this tick's report
      # @return [Boolean] true when the Hub answered
      def report(report)
        @last_report = report
        state = remote(false) { @hub.report(@name, report) }
        return false unless state

        @state = state
        true
      end

      # Liveness apart from the tick: the last report again, freshly
      # stamped, every +interval+ seconds, so an action that blocks
      # longer than REPORT_STALE does not read as a lost follower. The
      # leader's phase and target ride back on each answer.
      #
      # @param interval [Numeric] seconds between repeated reports
      # @return [Thread] the pulse thread
      def keep_alive!(interval: PULSE)
        stop_pulse!
        @pulse = Thread.new do
          loop do
            sleep interval
            begin
              next unless @last_report

              again = @last_report.dup
              again.at = nil
              state = remote(false) { @hub.report(@name, again) }
              @state = state if state
            rescue StandardError
              nil # as the leader's pulse: a raise here used to end
            end # liveness for good, with nothing logged
          end
        end
      end

      # Kill the keep_alive! pulse, if one runs.
      #
      # @return [nil]
      def stop_pulse!
        @pulse&.kill
        @pulse = nil
      end

      # This hunt's orders, a stale attack dropped.
      #
      # @bigshot stale attack
      # @param room [Integer] the follower's current room
      # @param now [Time] the clock to age attack orders against
      # @return [Array<Order>] the orders to act on, oldest first
      def orders(room:, now: @clock.now)
        Array(remote([]) { @hub.take_orders(@name) }).select do |o|
          o.hunt_id == @hunt_id && !(o.type == :attack && o.stale?(room, now))
        end
      end

      # Acknowledge an order type to the leader.
      #
      # @param type [Symbol] the order type
      # @return [Boolean] true when the Hub took it, false on any failure
      def ack(type)
        remote(false) { @hub.ack(type, @name, hunt_id: @hunt_id) }
      end

      # The leader's state, fetched fresh; the last known one on failure.
      #
      # @return [Hash] name, room, phase, looter, target
      def leader_state
        state = remote { @hub.leader_state }
        @state = state if state
        @state
      end

      # @return [String, nil] the leader's name, from the state or the Hub
      def leader_name = @state[:name] || remote { @hub.leader_name }
      # @return [Integer, nil] the leader's room from the last known state
      def leader_room = @state[:room]
      # @return [Symbol, nil] the leader's phase from the last known state
      def leader_phase = @state[:phase]

      # A leader published before this flag existed, or a state not yet
      # fetched, must not silently hold a follower's signs forever. Absent
      # reads as wanted, the behavior without the gate.
      # @return [Boolean] the leader is where signs belong
      def leader_signs_wanted? = @state.fetch(:signs, true) != false
      # @return [Hash, nil] the leader's target (:id, :name, :noun) from the last known state
      def leader_target = @state[:target]
      # @return [String, nil] the assigned looter from the last known state
      def looter = @state[:looter]

      # The leader's rooms, fetched once and kept.
      #
      # Only a real answer is kept. A failed fetch used to memoize {},
      # which is truthy, so ||= never retried and every later rally,
      # waypoint and resting-room order was a no-op for the life of the
      # script - one transient timeout stranded the follower for good.
      #
      # @return [Hash] :rally, :hunting, :waypoints, :resting; empty until one arrives
      def rooms
        return @rooms if @rooms

        answer = remote(nil) { @hub.rooms }
        answer.is_a?(Hash) && !answer.empty? ? (@rooms = answer) : {}
      end

      # Whether the leader is still heartbeating; false once this link is lost.
      #
      # @return [Boolean]
      def leader_alive?
        return false if @lost

        remote(false) { @hub.leader_alive? } ? true : false
      end

      # @return [Symbol, String, nil] why the leader finished, nil while it has not
      def finished_reason = remote { @hub.finished_reason }

      private

      # A remote call with a deadline; nil (or +default+) and a lost
      # leader on any failure.
      def remote(default = nil)
        result = default
        done = false
        thread = Thread.new do
          result = yield
          done = true
        rescue StandardError
          done = false
        end
        thread.join(@deadline)
        unless done
          thread.kill
          @lost = true
          return default
        end
        result
      end
    end
  end

  module Actions
    # GROUP OPEN, as bigshot sends it before every follower wait.
    #
    # @bigshot group open
    class GroupOpen < Base
      # The game's answer to GROUP OPEN, either way.
      ANSWER = /Your group status is now (?:open|closed)|Your group status/

      # Lich's Group tracks the status through its observer; the send goes
      # out only when it says the group is not open.
      #
      # @return [Symbol] :ok, :dead or :already_open
      def preconditions
        return :dead if me.dead?
        return :already_open if @world.group_open?

        :ok
      end

      # @return [Actions::Result] the matched answer, or a timeout
      def perform = send_and_match('group open', ANSWER, timeout: 3)
    end

    # DISBAND GROUP for independent travel.
    #
    # @bigshot disband group
    class Disband < Base
      # The game's answer to DISBAND GROUP, with or without a group.
      ANSWER = /You have no group to disband|You disband your group/

      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok
      # @return [Actions::Result] the matched answer, or a timeout
      def perform = send_and_match('disband group', ANSWER, timeout: 3)
    end

    # LEAVE GROUP, the follower's independent return.
    #
    # @bigshot leave group
    class LeaveGroup < Base
      # The game's answer to LEAVE GROUP, in a group or not.
      ANSWER = /You leave|But you are not in a group/

      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok
      # @return [Actions::Result] the matched answer, or a timeout
      def perform = send_and_match('leave group', ANSWER, timeout: 3)
    end

    # JOIN <leader> (group_all_followers 9312): the leader must be here.
    # JOIN the leader through Lich's Group.join (lich-5 #1591): the
    # follower's side of Group.add, which sends by id, reads the answer
    # and lets the observer record the new leader.
    #
    # @bigshot group_all_followers
    class Join < Base
      # @param world [World]
      # @param leader [String] the leader's noun, as the room lists it
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, leader:, **opts)
        super(world, **opts)
        @leader = leader.to_s
      end

      # @return [Symbol] :ok, :dead or :no_leader when the leader is not here
      def preconditions
        return :dead if me.dead?
        return :no_leader unless Array(@world.room.players).any? { |p| p.noun.to_s == @leader }

        :ok
      end

      # Group.join's answer as a Result: :joined, :already_member, :not_here
      # (no error text: the leader was not found) or :closed.
      #
      # @return [Actions::Result]
      def perform
        answer = group_join(@leader)
        return Result.new(status: :success, reason: :joined) if answer.key?(:ok)
        return Result.new(status: :success, reason: :already_member) if answer.key?(:noop)
        return Result.new(status: :failed, reason: :not_here) if answer[:err].nil?

        Result.new(status: :failed, reason: :closed)
      end

      # The seam to Lich's Group.join, stubbed in specs.
      #
      # @param leader [String] the leader's noun
      # @return [Hash] Group.join's answer, keyed :ok, :noop or :err
      def group_join(leader) = ::Lich::Gemstone::Group.join(leader)
    end
  end

  module Behaviors
    # The leader's holds between fights (do_hunt 7401-7413): stand every
    # follower down and wait for its movement acknowledgement, hold while
    # anyone is stunned or in roundtime, and call a missing follower back
    # before moving on. Followers gone quiet are reported once and no
    # longer waited on.
    #
    # @bigshot do_hunt
    class Muster < Behavior
      # Seconds between repeated follow_now calls to a missing follower.
      REORDER = 10

      # @param leader [Group::Leader] the leader's view of the Hub
      # @param resting [#call] -> Boolean, true while the leader is resting
      # @param fight [#call] (world) -> Boolean, true while a fight is on
      # @param clock [#now] the time source
      def initialize(leader:, resting:, fight:, clock: Time)
        super()
        @leader = leader
        @resting = resting
        @fight = fight
        @clock = clock
        @called_at = nil
        @reason = nil
        @movement_room = nil
        @movement_requested = false
        @movement_ready = false
      end

      # @return [Integer] 15, above Engage and Rest
      def priority = 15

      # Reports newly lost followers, then decides whether to hold: not
      # when solo, resting or fighting; else for a stunned or roundtimed
      # member, a missing follower, or the movement barrier.
      #
      # @param world [World]
      # @return [Boolean] true when there is a reason to hold
      def wants_control?(world)
        @leader.newly_lost.each { |n| Events.emit(:follower_lost, name: n) }
        return false if @leader.solo? || @resting.call
        if @fight.call(world)
          reset_movement(world.room.id)
          return false
        end

        reset_movement(world.room.id) if @movement_room != world.room.id

        @reason = if EO::Engine::Survival::Predicates.group_member_stunned?(world) then :member_stunned
                  elsif @leader.roundtime? then :member_roundtime
                  elsif !@leader.all_present?(world) then :follower_missing
                  elsif !@movement_requested then :prepare_movement
                  elsif !@movement_ready then :movement_barrier
                  end
        !@reason.nil?
      end

      # One step of the hold: nothing for a stun or roundtime, the
      # prepare_move order, the barrier check, or a follow_now call-back
      # (GROUP OPEN and unhide first) at most every REORDER seconds.
      #
      # @param world [World]
      # @return [Actions::Result, nil] the step's result, nil when only waiting
      def tick(world)
        return nil if %i[member_stunned member_roundtime].include?(@reason)
        if @reason == :prepare_movement
          @leader.prepare_movement(world.room.id)
          @movement_requested = true
          return Actions::Result.new(status: :success, reason: :prepare_movement)
        end
        if @reason == :movement_barrier
          return nil unless @leader.movement_ready?(world)

          @movement_ready = true
          return Actions::Result.new(status: :success, reason: :movement_ready)
        end
        return nil if @called_at && @clock.now - @called_at < REORDER

        @called_at = @clock.now
        Events.emit(:waiting_for_followers, reason: @reason, room: world.room.id)
        Actions::GroupOpen.new(world).call
        Actions::Command.new(world, command: 'unhide').call if world.me.hidden?
        @leader.order(:follow_now, room: world.room.id)
        Actions::Result.new(status: :success, reason: :called_back)
      end

      private

      def reset_movement(room)
        @movement_room = room
        @movement_requested = false
        @movement_ready = false
      end
    end

    # The follower's Rest: the leader's orders, one step per tick, on
    # Rest's own step machinery (prep lists, trips, fog). The rooms come
    # from the leader's profile (return_waypoints_ids 1110, resting_id
    # 1115, hunting_id 1120, rally_ids 1125); the command and script lists
    # are the follower's own. A hunt_over is acked and reported.
    #
    # @bigshot return_waypoints_ids, resting_id, hunting_id, rally_ids
    class Orders < Rest
      # @return [Boolean] true once the resting scripts order has finished
      attr_reader :rest_prep_done

      # @param member [Group::Member]
      # @param policy [Rest::Policy] the follower's own rest settings
      # @param counters [Rest::Counters] the follower's rest counters
      # @param assist [Behaviors::Assist, nil] told to attack and stand down
      # @param follow [Behaviors::Follow, nil] told to rejoin and to travel alone
      # @param loot [Behaviors::Loot, nil] assigned the loot
      # @param sneaky [Boolean] the follower's sneaky_sneaky
      # @param travel [#call, nil] (room) -> Trip or Boolean; default a Travel trip
      # @param fog [#call, nil] (policy, reason) -> Boolean; default Rest::Fog.return
      # @param scripts [Object, nil] start(name, args), running?(name), kill(name)
      # @param stance [#call, nil] (name) -> Boolean; default Lich's Stance.change
      # @param clock [#now] the time source
      def initialize(member:, policy:, counters: EO::Engine::Rest::Counters.new, assist: nil, follow: nil, loot: nil, sneaky: false,
                     travel: nil, fog: nil, scripts: nil, stance: nil, clock: Time)
        super(policy: policy, counters: counters, travel: travel, fog: fog, scripts: scripts, stance: stance, loot: nil, clock: clock)
        @member = member
        @assist = assist
        @follow = follow
        @loot = loot
        @sneaky = sneaky
        @queue = []
        @phase = :idle
        @rest_prep_done = false
        @commands = []
        @script_list = []
        @rooms = []
        @room = nil
        @after = nil
        @pending_ack = nil
      end

      # @return [Integer] 20, where Rest sits
      def priority = 20

      # @return [String] 'orders'
      def name = 'orders'

      # Movement orders step through rooms faster than the engine's fire budget.
      #
      # @return [nil] no budget
      def fire_budget = nil

      # The follower never decides to rest; the leader's phase says.
      #
      # @return [Boolean] true while the leader's phase is :resting
      def resting? = @member.leader_phase == :resting

      # What Maintain gates on: the leader is at the hunting room, so
      # signs are wanted. Held for the refuge and both walks.
      # @return [Boolean]
      def signs_wanted? = @member.leader_signs_wanted?

      # Pulls this tick's orders from the Hub into the queue.
      #
      # @param world [World]
      # @return [Boolean] true while a step, an order or an ack is pending
      def wants_control?(world)
        @queue.concat(@member.orders(room: world.room.id, now: @clock.now))
        @phase != :idle || @queue.any? || !@pending_ack.nil?
      end

      # The step in progress; else the pending prepare_move ack once out
      # of roundtime; else the next queued order begun.
      #
      # @param world [World]
      # @return [Actions::Result, nil] the step's result, nil when nothing acted
      def tick(world)
        return step(world) unless @phase == :idle
        if @pending_ack
          return nil if world.me.in_rt? || world.me.in_cast_rt?

          type = @pending_ack
          @pending_ack = nil
          @member.ack(type)
          return Actions::Result.new(status: :success, reason: :movement_ready)
        end

        order = @queue.shift
        return nil if order.nil?

        Events.emit(:order, type: order.type, payload: order.payload)
        begin_order(world, order)
      end

      private

      def rooms = @member.rooms || {}

      def begin_order(world, order)
        case order.type
        when :attack then @assist&.attack!; nil
        when :follow_now then @assist&.stand_down!; @follow&.rejoin!; nil
        when :prepare_move
          @assist&.stand_down!
          @follow&.rejoin!
          @pending_ack = :prepare_move
          nil
        when :prep_rest
          # The leader's return cycle answers a forced rest we reported;
          # the reason has done its work.
          @forced_reason = nil
          @assist&.stand_down!
          @stance.call(@policy.wander_stance) if @policy.wander_stance
          Actions::Result.new(status: :success)
        when :hunting_prep then prep(@policy.hunting_prep_command_list, [], wait_for_scripts: true)
        when :hunting_scripts_start then prep([], @policy.hunting_script_list)
        when :hunting_scripts_stop
          stop_hunting(world)
          Actions::Result.new(status: :success)
        when :cast_signs then nil # Maintain casts what is due
        when :check_sneaky then @sneaky && !world.me.hidden? ? Actions::Hide.new(world).call : nil
        when :go2_rally then travel(Array(rooms[:rally]))
        when :go2_hunting_room then room(rooms[:hunting])
        when :leave_group
          @follow&.independent!
          Actions::LeaveGroup.new(world).call
        when :fog_return
          @reason = 'ordered'
          @phase = :fog
          nil
        when :go2_waypoints then travel(Array(rooms[:waypoints]))
        when :go2_resting_room then room(rooms[:resting])
        when :resting_prep
          @rest_prep_done = false
          @counters.reset!
          prep(@policy.resting_command_list, [], wait_for_scripts: true)
        when :resting_scripts_start
          @after = -> { @rest_prep_done = true }
          prep([], @policy.resting_script_list, wait_for_scripts: true)
        when :loot
          if order.payload.to_s == @member.name
            @assist&.stand_down!
            @loot&.assign!
          end
          nil
        when :unhide then world.me.hidden? ? Actions::Command.new(world, command: 'unhide').call : nil
        when :follower_overkill then overkill(world)
        when :hunt_over
          @member.ack(:hunt_over)
          Events.emit(:hunt_over, reason: order.payload)
          nil
        when :command then Actions::Command.new(world, command: order.payload.to_s).call
        end
      end

      def prep(commands, scripts, wait_for_scripts: false)
        @commands = commands
        @script_list = scripts
        @wait_for_scripts = wait_for_scripts
        @remaining = nil
        @phase = :prep
        nil
      end

      def travel(list)
        @rooms = list
        @remaining = nil
        @phase = :travel
        nil
      end

      def room(id)
        @room = id
        @attempts = 0
        @phase = :room
        nil
      end

      def step(world)
        result = case @phase
                 when :prep then step_prep(world, @commands, @script_list, :idle, wait_for_scripts: @wait_for_scripts)
                 when :travel then step_travel(world, @rooms, :idle)
                 when :room then step_room(world, @room, :idle)
                 when :fog then step_fog(world)
                 when :custom_fog then step_custom_fog(world)
                 end
        if @phase == :idle && @after
          @after.call
          @after = nil
        end
        result
      end

      # Rest's fixed successors, redirected to idle.
      def after_fog = :idle
      def stuck_phase(_next_phase) = :idle
      def finish = (@phase = :idle)

      # FOLLOWER_OVERKILL (add_event 2887, use_lte_boost 10100): the
      # leader's kill counts here too.
      def overkill(world)
        boost = Actions::LteBoost.new(world, counters: @counters, policy: @policy).call
        return boost if boost.success?

        if EO::Engine::Rest::Predicates.fried?(world.me, @policy) && EO::Engine::Rest::Predicates.lte_boosts_spent?(@counters, @policy)
          @counters.overkill += 1
          Events.emit(:overkill, count: @counters.overkill, max: @policy.overkill_max)
        end
        Actions::Result.new(status: :success, reason: :counted)
      end
    end

    # The follower's Engage (the tail's :ATTACK loop 10105-10149): after
    # an attack order, the leader's target while it stands, else our own
    # choice by the same rules, until the leader says move or loot. Never
    # without the leader in the room (7794; should_flee? 8543 refuses a
    # fight with nobody here).
    #
    # @bigshot :ATTACK loop, leader present, should_flee?
    class Assist < Engage
      # @param member [Group::Member] the link to the leader
      # @param opts [Hash] Engage's own arguments (policy, targets_policy, ...)
      def initialize(member:, **opts)
        super(**opts)
        @member = member
        @attacking = false
      end

      # @return [String] 'assist'
      def name = 'assist'

      # An attack order: fight until stood down.
      #
      # @return [Boolean] true
      def attack! = @attacking = true
      # A move or loot order: stop fighting.
      #
      # @return [Boolean] false
      def stand_down! = @attacking = false

      # Only after an attack order, with the leader here and a target
      # to take.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        return false unless @attacking
        return false unless leader_here?(world)

        !next_target(world).nil?
      end

      private

      def leader_here?(world)
        leader = @member.leader_name.to_s
        Array(world.room.players).any? { |p| p.noun.to_s == leader }
      end

      # 10124-10135: the leader's target when it is here and alive, else
      # ours; a better rank still takes over with priority.
      def next_target(world)
        wanted = @member.leader_target
        return nil unless wanted

        leaders = Array(world.room.targets).find { |t| t.id.to_s == wanted[:id].to_s }
        return nil unless leaders && leaders.status.to_s !~ /dead|gone/

        Targets.choose(world.room.targets, @targets_policy, current: leaders, priority: @policy.priority)
      end
    end

    # The follower's Wander (group_all_followers 9305): not with the
    # leader, go2 the leader's room; there and not in the group, JOIN.
    # After a leave_group order the follower travels on its own orders
    # until the next follow_now.
    #
    # @bigshot group_all_followers
    class Follow < Behavior
      # @param member [Group::Member] the link to the leader
      # @param travel [#call, nil] (room) -> Trip or Boolean; default a Travel trip
      # @param clock [#now] the time source
      def initialize(member:, travel: nil, clock: Time)
        super()
        @member = member
        @travel = travel || EO::Engine::Travel.default
        @clock = clock
        @trip = nil
        @independent = false
        @rejoin = false
      end

      # @return [Integer] 60, where Wander sits
      def priority = 60

      # @return [String] 'follow'
      def name = 'follow'

      # The trip to the leader steps through rooms faster than the engine's fire budget.
      #
      # @return [nil] no budget
      def fire_budget = nil

      # Drop the trip in progress.
      #
      # @return [void]
      def cancel! = EO::Engine::Travel.cancel(self)
      # A higher behavior took over: suspend the trip to resume later.
      #
      # @param _world [World] unused
      # @return [void]
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # A follow_now or prepare_move order: back to following the leader.
      #
      # @return [Boolean] false, the cleared independent flag
      def rejoin!
        @rejoin = true
        @independent = false
      end

      # A leave_group order: travel on Orders alone until rejoin!.
      #
      # @return [Boolean] true
      def independent! = @independent = true

      # Not while independent; always mid-trip; else when the leader is
      # not here or we are not in the group.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        return false if @independent
        return true if @trip

        !leader_here?(world) || !grouped?(world)
      end

      # One step: skipped in roundtime; a trip step toward the leader's
      # room when not with the leader; JOIN when here but not grouped.
      #
      # @param world [World]
      # @return [Actions::Result, nil] nil mid-trip or when already following
      def tick(world)
        if world.me.in_rt? || world.me.in_cast_rt?
          return Actions::Result.new(status: :skipped, reason: :roundtime)
        end

        unless leader_here?(world)
          room = @member.leader_room
          return Actions::Result.new(status: :failed, reason: :no_leader_room) if room.nil?
          return Actions::Result.new(status: :success, reason: :leader_room) if room == world.room.id

          case EO::Engine::Travel.step(self, @travel, room, world)
          when :underway then return nil
          when :arrived then return Actions::Result.new(status: :success, reason: :arrived)
          else return Actions::Result.new(status: :failed, reason: :could_not_reach)
          end
        end
        return Actions::Join.new(world, leader: @member.leader_name).call unless grouped?(world)

        @rejoin = false
        nil
      end

      private

      def leader_here?(world)
        leader = @member.leader_name.to_s
        Array(world.room.players).any? { |p| p.noun.to_s == leader }
      end

      def grouped?(world)
        leader = @member.leader_name.to_s
        world.group_leader_noun.to_s == leader || world.group_nouns.include?(leader)
      end
    end
  end
end
