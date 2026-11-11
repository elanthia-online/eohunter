# frozen_string_literal: true

# ============================================================================
# cleanse (ecleanse 2.3.6 folded in: status removal, hazards, disarm
#          recovery, hive traps, the itchy curse)
# ============================================================================

#
# ecleanse is a main loop that reads the character's afflictions
# and the room's hazards every 0.2 s into an event stack, a DownstreamHook
# (1618) that queues the line-driven ones (disarms, the sanctum transform,
# the infected wound, weapon webbing, hive traps, the itchy curse, the
# entangling bind), and one Action per event that pauses every other
# script while it works (System.scripts_pause). The engine's Cleanse is
# that as the behavior at priority 5: wants_control? is the condition
# list, the Watch carries the line rules, and taking the tick IS the
# pause. Each ecleanse Action is an engine Action with the same gates and
# the same commands, bounded where ecleanse loops. Settings come from
# the hunt's `recovery` mapping, set in ;eohunter setup. Rules and ecleanse
# line references in hunting-engine-plan.md, "Cleanse".
#
module EO::Engine
  # ecleanse's afflictions and hazards as a Policy, the run's State, the
  # spell lookups and the Predicates that pick a job each tick. The
  # actions and the priority-5 behavior sit under Actions and Behaviors.
  module Cleanse
    # Every Cleanse preference the Policy carries (ecleanse's own names).
    KEYS = %i[
      cleanse_magical cleanse_grounded cleanse_poison cleanse_disease recover_disarmed
      dispel_magic avoid_webs use_berserk_webbed hive_traps_apparatus hive_traps_ground
      break_runestone determination itchy_curse safe_room use_stunned_barkskin use_berserk_stunned
      use_stunned1040 use_stance1 use_stance2 use_flee use_hide use_709 use_619 use_213 use_1011
      use_9811 use_140 use_919 use_1635
      troubadours_rally stand_stance
    ].freeze

    # The preferences, one member per KEYS entry: every toggle false and
    # safe_room "" unless the hunt says otherwise.
    Policy = Struct.new(*KEYS, keyword_init: true) do
      # @param opts [Hash{Symbol => Object}] KEYS values; keys outside
      #   KEYS are dropped
      def initialize(**opts)
        defaults = KEYS.to_h { |k| [k, k == :safe_room ? '' : false] }
        super(**defaults.merge(opts.slice(*KEYS)))
      end
    end

    # ecleanse Data: the spells this character has for each job, the
    # hazard patterns, the ids the game refused to target, the queued line
    # events, the disarm records.
    class State
      # Most refused ids kept, the oldest dropped first (CappedCollection 189).
      CAPPED = 200 # CappedCollection

      # The queued line events, the ids the game refused to TARGET, the
      # disarm records by key, the room a hive trap was seen in, and the
      # sanctum creature's noun.
      #
      # @return [Array<Hash>, Array<String>, Hash{Integer => Hash}, Integer, String, nil]
      attr_reader :queue, :bad_targets, :recover, :hive_trap_room, :creature
      # The next disarm record key, and when a group member last got
      # Troubadour's Rally.
      #
      # @return [Integer, Time, nil]
      attr_accessor :recover_seq, :rally_member_at
      # Group aid: when each [victim, kind] need was first seen and last
      # cast for, and the need the last reason picked.
      #
      # @return [Hash{Array => Time}, Hash{Array => Time}, Aid::Need, nil]
      attr_reader :aid_seen, :aid_cast_at, :aid_cleared
      attr_accessor :aid_need

      def initialize
        @queue = []
        @bad_targets = []
        @recover = {}
        @recover_seq = 0
        @hive_trap_room = nil
        @creature = nil
        @rally_member_at = nil
        @aid_seen = {}
        @aid_cast_at = {}
        @aid_cleared = {}
        @aid_need = nil
      end

      # Remember an id the game refused to TARGET, within the cap.
      #
      # @param id [Integer, String]
      # @return [void]
      def bad_target!(id)
        @bad_targets << id.to_s
        @bad_targets.shift while @bad_targets.size > CAPPED
      end

      # The game refused to TARGET this id before.
      #
      # @param id [Integer, String]
      # @return [Boolean]
      def bad_target?(id) = @bad_targets.include?(id.to_s)

      # Queue a line event once; a duplicate already waiting is dropped.
      #
      # @param event [Hash] `:event` names the job, `:key` a disarm record
      # @return [void]
      def enqueue(event)
        @queue << event unless @queue.include?(event)
      end

      # The room a hive trap was seen in; nil once the trap is dealt with.
      #
      # @param room [Integer, nil]
      # @return [Integer, nil]
      def hive_trap_room=(room)
        @hive_trap_room = room
      end

      # The creature that transformed our weapon in the sanctum.
      #
      # @param noun [String, nil]
      # @return [String, nil]
      def creature=(noun)
        @creature = noun
      end

      # record_disarm: the ids in hand at the moment of the disarm,
      # so the recovered weapon is one that was not already there.
      #
      # @param noun [String, nil] the disarmed weapon's noun
      # @param hands [#right, #left] the hands at that moment
      # @param room_id [Integer, nil] where it happened
      # @param room_title [String, nil]
      # @return [Integer] the record's key, for the queued event
      def record_disarm(noun, hands, room_id, room_title)
        known = [hands.right, hands.left].map { |h| h&.id }.reject { |id| id.nil? || id.to_s.empty? }.map(&:to_s)
        key = @recover_seq
        @recover_seq += 1
        @recover[key] = { noun: noun, known_ids: known, room_id: room_id, title: room_title }
        key
      end
    end

    # The debuffs the dispel clears, as one pattern over the debuff names.
    DEBUFFS = /Confusion|Vertigo|Sounds|Thought Lash|Mindwipe|Pious Trial|Powersink/
    # The same debuffs, one name per cast (remove_magical 1337).
    DISPELLABLE = ['Confusion', 'Vertigo', 'Sounds', 'Thought Lash', 'Mindwipe', 'Pious Trial', 'Powersink'].freeze
    # The loot names that are a magic globe to dispel (avoid_globe 716).
    MAGIC_GLOBES = /silvery blue globe|spiraling ghostly rift|chaotic spatial anomaly/i
    # The loot name that is a runestone to break (avoid_runestone 748).
    RUNESTONES = /pale hovering runestone/i
    # Clouds the dispel does not answer; the acidic mist takes the breeze.
    INVALID_CLOUDS = ['cloud of acidic mist', 'cloud of thick ethereal fog'].freeze
    # The Wounds keys the Sigil of Determination is worth casting for.
    INJURY_LOCATIONS = %w[leftHand rightHand leftArm rightArm leftEye rightEye nsys head].freeze
    # Every answer TARGET gives to a hazard, accepted or refused.
    TARGET_ANSWERS = Regexp.union(
      /^You can only target creatures, players, and creature-created hazards\.$/,
      /^Usage:  TARGET \{player\|creature\|hazard\}$/,
      /^You are now targeting .+\.$/,
      /^You are unable to discern the origin of .+\.$/,
      /^You discern that you are the origin of .+ and decide against targeting yourself\.$/,
      /^Suspecting that .+ is the origin of .+, you turn your attention towards \w+!$/
    )
    # The one TARGET answer that means the hazard is now targeted.
    TARGET_OK = /^Suspecting that .+ is the origin of .+, you turn your attention towards \w+!$/

    # Which spell this character has for each job (Data 224-228).
    module Spells
      module_function

      # The first spell in +nums+ the character knows, in that order.
      #
      # @param world [World]
      # @param nums [Array<Integer>] spell numbers, preferred first
      # @return [Object, nil] the Spell, or nil when none is known
      def first_known(world, nums)
        nums.map { |n| world.spell[n] }.compact.find(&:known?)
      end

      # 113 for disease.
      #
      # @param world [World]
      # @return [Object, nil]
      def disease(world) = first_known(world, [113])
      # 114 for poison.
      #
      # @param world [World]
      # @return [Object, nil]
      def poison(world) = first_known(world, [114])
      # 417, 1218 or 119 for a dispel.
      #
      # @param world [World]
      # @return [Object, nil]
      def dispel(world) = first_known(world, [417, 1218, 119])
      # 209 or a dispel for a web.
      #
      # @param world [World]
      # @return [Object, nil]
      def webs(world) = first_known(world, [209, 417, 1218, 119])
      # 912 or 612 for the acidic mist.
      #
      # @param world [World]
      # @return [Object, nil]
      def breeze(world) = first_known(world, [912, 612])
    end

    # Whether our wounds and scars allow a cast: Lich's
    # Injured.able_to_cast? (head, nerves, eyes, arms and hands against
    # the casting limits, an active Sigil of Determination lifting a
    # rank-2 block). When the sigil would help but is not up, the
    # :determination step below casts it first and the cleanse follows
    # on the next tick; nothing is pre-approved on a sigil not yet cast.
    module Casting
      module_function

      # Lich's Injured.able_to_cast? for this character.
      #
      # @param world [World]
      # @param _policy [Policy, nil] unused; kept for the callers' shape
      # @return [Boolean]
      def able?(world, _policy = nil)
        world.me.able_to_cast?
      end

      # The policy wants the sigil, and it is known and affordable.
      #
      # @param world [World]
      # @param policy [Policy]
      # @return [Boolean]
      def determination?(world, policy)
        return false unless policy.determination

        s = world.spell['Sigil of Determination']
        s && s.known? && s.affordable?
      end
    end

    # The conditions ecleanse's main loop reads, each from the World and
    # State without sending anything; `reason` runs them in its order.
    module Predicates
      module_function

      # A cloud in the room's loot to dispel: any cloud but the invalid
      # ones and gem clouds, else the acidic mist when a breeze is known.
      # Refused ids are skipped.
      #
      # @param world [World]
      # @param state [State]
      # @return [Object, nil] the loot object, or nil
      def cloud(world, state)
        loot = Array(world.room.loot)
        found = loot.find { |l| l.name.to_s =~ /cloud/i && !INVALID_CLOUDS.include?(l.name.to_s) && l.type.to_s !~ /\bgem\b/i && !state.bad_target?(l.id) }
        found || (Spells.breeze(world) && loot.find { |l| l.name.to_s == 'cloud of acidic mist' && !state.bad_target?(l.id) })
      end

      # A magic globe here, not yet refused.
      #
      # @param world [World]
      # @param state [State]
      # @return [Object, nil] the loot object, or nil
      def globe(world, state) = Array(world.room.loot).find { |l| l.name.to_s =~ MAGIC_GLOBES && !state.bad_target?(l.id) }
      # A runestone here, not yet refused.
      #
      # @param world [World]
      # @param state [State]
      # @return [Object, nil] the loot object, or nil
      def runestone(world, state) = Array(world.room.loot).find { |l| l.name.to_s =~ RUNESTONES && !state.bad_target?(l.id) }
      # A web here (by noun), not yet refused.
      #
      # @param world [World]
      # @param state [State]
      # @return [Object, nil] the loot object, or nil
      def web(world, state) = Array(world.room.loot).find { |l| l.noun.to_s =~ /web/i && !state.bad_target?(l.id) }

      # Lich's CMan.available?: known, affordable at the table's stamina
      # (7, where ecleanse guessed 10), off cooldown, not overexerted.
      #
      # @param _world [World] unused
      # @return [Boolean]
      def can_cleave?(_world) = cman_available?('Spell Cleave')
      # Spell Thieve by the same test as `can_cleave?`.
      #
      # @param _world [World] unused
      # @return [Boolean]
      def can_thieve?(_world) = cman_available?('Spell Thieve')

      # Lich's CMan.known?, false when Lich cannot answer.
      #
      # @param name [String] the maneuver's name
      # @return [Boolean]
      def cman_known?(name)
        ::Lich::Gemstone::CMan.known?(name)
      rescue StandardError
        false
      end

      # ecleanse main_loop in its order, gated the way each
      # Action gates itself so the behavior only claims a tick it can use.
      #
      # @param world [World]
      # @param policy [Policy]
      # @param state [State]
      # @param aid [Aid::Link, nil] the group's roster; nil alone
      # @return [Symbol, nil] :queued, :rally, :rally_member, :aid, :poison,
      #   :disease, :stun, :web_bound, :grounded, :magical, :cloud, :globe,
      #   :runestone, :web, :determination, or nil for nothing to do
      # @bigshot group_status_ailments
      # @bigshot cmd_1040
      def reason(world, policy, state, aid: nil)
        return :queued if state.queue.any?

        me = world.me
        # bigshot group_status_ailments: with troubadours_rally and
        # 1040 known, a webbed, sleeping, stunned or frozen self gets
        # Troubadour's Rally before anything else, until clear (cmd_1040
        # 6281); a group member showing an ailment gets one cast.
        if policy.troubadours_rally && world.spell[1040]&.known?
          return :rally if rally_needed?(me)
          return :rally_member if aid.nil? && member_needs_rally?(world, state)
        end
        # A groupmate's need comes before our own poison: we can carry a
        # poison, and a stunned friend may not live through the wait.
        if aid && (need = Aid.pick(world, aid.roster, aid.name, state))
          state.aid_need = need
          return :aid
        end

        debuffs = me.debuff_names
        thorns = debuffs.any? { |k| k =~ /Wall of Thorns Poison/ }
        return :poison if policy.cleanse_poison && (me.poisoned? || thorns) && Spells.poison(world) && Casting.able?(world, policy)
        return :disease if policy.cleanse_disease && me.diseased? && Spells.disease(world) && Casting.able?(world, policy)
        return :stun if me.stunned? && stun_means?(world, policy)
        return :web_bound if (me.webbed? || me.bound?) && web_bound_means?(world, policy)
        return :grounded if policy.cleanse_grounded && debuffs.any? { |k| k =~ /Rooted|Pressed/ } && grounded_means?(world)
        return :magical if policy.cleanse_magical && debuffs.any? { |k| k =~ DEBUFFS } && Spells.dispel(world) && Casting.able?(world, policy)
        return :cloud if policy.dispel_magic && cloud(world, state) && hazard_means?(world, policy, cloud(world, state))
        return :globe if policy.dispel_magic && globe(world, state) && hazard_means?(world, policy, nil)
        return :runestone if policy.break_runestone && runestone(world, state)
        return :web if policy.avoid_webs && web(world, state) && (Spells.webs(world) && Casting.able?(world, policy) || can_cleave?(world) || can_thieve?(world))
        return :determination if policy.determination && injured_for_sigil?(world) && Casting.determination?(world, policy) && !me.effect_active?('Sigil of Determination')

        nil
      end

      # We are webbed, sleeping, stunned or frozen: what 1040 on
      # ourselves answers.
      #
      # @param me [Object] the World's character
      # @return [Boolean]
      def rally_needed?(me)
        me.webbed? || me.sleeping? || me.stunned? || me.frozen?
      end

      # A group member here with an ailment, one cast each
      # RALLY_MEMBER_EVERY seconds (bigshot casts once per command).
      #
      # @bigshot group_status_ailments
      RALLY_MEMBER_EVERY = 10

      # A group member here shows a STUNNED status, and the last member
      # cast was RALLY_MEMBER_EVERY seconds ago or more.
      #
      # @param world [World]
      # @param state [State] carries rally_member_at
      # @param now [Time] the clock, for specs
      # @return [Boolean]
      def member_needs_rally?(world, state, now = Time.now)
        return false if state.rally_member_at && now - state.rally_member_at < RALLY_MEMBER_EVERY

        nouns = world.group_nouns
        Array(world.room.players).any? { |p| p.status.to_s =~ EO::Engine::Survival::STUNNED && nouns.include?(p.noun.to_s) }
      end

      # Lich's Wounds ranks, by the body parts the sigil is worth casting for.
      #
      # @param world [World]
      # @return [Boolean] any INJURY_LOCATIONS wound at rank 2 or worse
      def injured_for_sigil?(world)
        wounds = world.me.wounds || {}
        INJURY_LOCATIONS.any? { |limb| wounds[limb].to_i > 1 }
      end

      # Something to clear a hazard with: the breeze for the acidic mist;
      # else a castable dispel, Spell Cleave or Spell Thieve.
      #
      # @param world [World]
      # @param policy [Policy]
      # @param cloud [Object, nil] the cloud in question, nil for a globe
      # @return [Boolean, Object, nil] truthy when a means exists
      def hazard_means?(world, policy, cloud)
        return Spells.breeze(world) && Casting.able?(world, policy) if cloud && cloud.name.to_s == 'cloud of acidic mist'

        (Spells.dispel(world) && Casting.able?(world, policy)) || can_cleave?(world) || can_thieve?(world)
      end

      # remove_stun: every means the policy allows and the character has
      #
      # @param world [World]
      # @param policy [Policy]
      # @return [Boolean] 1040, barkskin or 1635 anywhere; berserk, the
      #   Stun Maneuvers stances, flee or hide outside an escape room
      def stun_means?(world, policy)
        me = world.me
        escape_room = Actions::Escape.kind_for(world.room.title)
        return true if policy.use_stunned1040 && world.spell[1040]&.known?
        return true if policy.use_stunned_barkskin && world.spell[605]&.known? && !me.cooldown_active?('Barkskin: Commune') && !me.cooldown_active?('Barkskin') && !me.spell_active?(605) && me.blessings_ranks >= 15
        return true if policy.use_1635 && world.spell[1635]&.known?
        return false if escape_room

        (policy.use_berserk_stunned && cman_available?('Berserk')) ||
          (policy.use_stance1 && cman_available?('Stun Maneuvers', min_rank: 3)) ||
          (policy.use_stance2 && cman_available?('Stun Maneuvers', min_rank: 4)) ||
          (policy.use_flee && cman_available?('Stun Maneuvers', min_rank: 5)) ||
          (policy.use_hide && cman_available?('Stun Maneuvers', min_rank: 5) && !me.hidden?)
      end

      # Something for a web or bind, when the policy allows either job:
      # an affordable 1040, berserk with the stamina, an affordable 1635,
      # or Escape Artist with the stamina.
      #
      # @param world [World]
      # @param policy [Policy]
      # @return [Boolean]
      def web_bound_means?(world, policy)
        return false unless policy.avoid_webs || policy.use_berserk_webbed

        me = world.me
        (world.spell[1040]&.known? && world.spell[1040].affordable?) ||
          (policy.use_berserk_webbed && cman_known?('Berserk') && me.stamina >= 21) ||
          (policy.use_1635 && world.spell[1635]&.known? && world.spell[1635].affordable?) ||
          (feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15)
      end

      # Something for a root or press: Retreat with the stamina when
      # known, else Escape Artist for a root.
      #
      # @param world [World]
      # @return [Boolean]
      def grounded_means?(world)
        me = world.me
        return me.stamina >= 11 if cman_known?('Retreat')

        me.debuff_active?('Rooted') && feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
      end

      # Lich's CMan.available?, false when Lich cannot answer.
      #
      # @param name [String] the maneuver's name
      # @param min_rank [Integer] the rank the use needs
      # @return [Boolean]
      def cman_available?(name, min_rank: 1)
        ::Lich::Gemstone::CMan.available?(name, min_rank: min_rank)
      rescue StandardError
        false
      end

      # Lich's Feat.available?, false when Lich cannot answer.
      #
      # @param name [String] the feat's name
      # @param min_rank [Integer] the rank the use needs
      # @return [Boolean]
      def feat_available?(name, min_rank: 1)
        ::Lich::Gemstone::Feat.available?(name, min_rank: min_rank)
      rescue StandardError
        false
      end
    end

    # Group aid: a groupmate's ailment, fixed by whoever in the group can.
    #
    # ecleanse was written for one character, and bigshot's only group
    # help is 1040 (Stun Relief sits on its to-do list). Here every member
    # publishes the remedies it can cast at others and the ailments only
    # it can see; the leader merges them into the state that rides back on
    # every report, so each member holds the same roster. A need is a
    # groupmate here that the room shows stunned or muckled, or whose own
    # entry says poisoned or diseased. The members that could answer it
    # rank themselves by name, the same order on every character: the
    # first casts at once and each next one STAGGER seconds later, looking
    # again before it casts, so one problem draws one cast without a
    # message between them.
    module Aid
      module_function

      # The spells cast for a groupmate, per need, in preference order.
      REMEDIES = { stun: [108, 1040], muckled: [1040], poison: [114], disease: [113] }.freeze
      # Every spell a remedy names.
      SPELLS = REMEDIES.values.flatten.uniq.freeze
      # Seconds between one candidate's turn and the next one's.
      STAGGER = 1.5
      # Seconds a victim that can cure its own poison or disease has
      # before the others step in.
      SELF_GRACE = 4
      # Seconds before the same need on the same victim gets another cast:
      # long enough for the room, or the victim's report, to show the cure.
      REPEAT = { stun: 4, muckled: 4, poison: 8, disease: 8 }.freeze
      # A groupmate's room status that 108 answers, and those only 1040 does:
      # with STUN, all of Survival::STUNNED, the rally the aid replaces.
      STUN = /stunned/i
      MUCKLED = /webbed|sleeping|frozen|immobilized|held in place|horrified|staggered/i
      # Needs the victim may answer itself first.
      SELF_CURABLE = %i[poison disease].freeze
      # The game's word that a groupmate's stun is over, on the raw line
      # (names and the pronoun are links). Lich's room status lags it by a
      # moment: on 2026-11-10 a second 108 went out 0.2s after Monstr was
      # clear, on a status that still read stunned.
      CLEARED = %r{noun="(\w+)">\w+</a> shakes off .{0,120}?stunned state}

      # A need this character acts on: who, what, and the spell it casts.
      Need = Struct.new(:victim, :kind, :spell, keyword_init: true)

      # The behavior's view of the group: this character's name, and the
      # roster as the leader last merged it.
      Link = Struct.new(:name, :source, keyword_init: true) do
        # @return [Hash{String => Hash}] name => { helps:, ailments: }
        def roster
          r = source.call
          r.is_a?(Hash) ? r : {}
        rescue StandardError
          {}
        end
      end

      # This character's roster entry: the remedies it knows, and the
      # ailments no one else can see.
      #
      # @param world [World]
      # @return [Hash] { helps: [Integer], ailments: [Symbol] }
      def own(world)
        me = world.me
        ailments = []
        ailments << :poison if me.poisoned? || Array(me.debuff_names).any? { |k| k =~ /Wall of Thorns Poison/ }
        ailments << :disease if me.diseased?
        { helps: known(world), ailments: ailments }
      end

      # @param world [World]
      # @return [Array<Integer>] the remedy spells this character knows
      def known(world) = SPELLS.select { |n| world.spell[n]&.known? }

      # The group's members: Lich's Group, and every name on the roster.
      # On a follower Lich's Group only learns of members who join after
      # it does, so a follower that joined last knew only the leader and
      # never saw a groupmate's stun (2026-11-10, Monstr). The roster is
      # the hub's own list.
      #
      # @return [Array<String>]
      def members(world, roster) = world.group_nouns | roster.keys.map(&:to_s)

      # Every need in the room, as [victim, kind] pairs.
      #
      # @param world [World]
      # @param roster [Hash{String => Hash}]
      # @param name [String] this character
      # @return [Array<Array(String, Symbol)>]
      def needs(world, roster, name)
        grouped = members(world, roster)
        here = Array(world.room.players).select { |p| grouped.include?(p.noun.to_s) && p.status.to_s !~ /dead/i }
        list = here.filter_map do |p|
          status = p.status.to_s
          kind = if status =~ STUN then :stun
                 elsif status =~ MUCKLED then :muckled
                 end
          [p.noun.to_s, kind] if kind
        end
        present = here.map { |p| p.noun.to_s }
        roster.each do |who, entry|
          next if who == name || !present.include?(who)

          Array(entry && entry[:ailments]).each { |a| list << [who, a.to_sym] if REMEDIES.key?(a.to_sym) }
        end
        list.uniq
      end

      # The members that could answer a need, in turn order: here, not
      # muckled themselves, knowing one of its remedies. This character
      # stands in with what it knows, whatever the roster says.
      #
      # @return [Array<String>] sorted names
      def candidates(world, roster, name, mine, victim, kind)
        remedies = REMEDIES[kind]
        statuses = Array(world.room.players).to_h { |p| [p.noun.to_s, p.status.to_s] }
        pool = roster.filter_map do |who, entry|
          next if who == name || !statuses.key?(who)
          next if statuses[who] =~ EO::Engine::Survival::STUNNED || statuses[who] =~ /dead/i
          next if (Array(entry && entry[:helps]) & remedies).empty?

          who
        end
        pool << name unless (mine & remedies).empty?
        (pool.uniq - [victim]).sort
      end

      # The game said this groupmate's stun ended, within REPEAT[:stun].
      #
      # @return [Boolean]
      def cleared?(state, victim, now = Time.now)
        at = state.aid_cleared[victim]
        !at.nil? && now - at < REPEAT[:stun]
      end

      # The need this character should answer now, if any.
      #
      # @param world [World]
      # @param roster [Hash{String => Hash}]
      # @param name [String] this character
      # @param state [State] carries aid_seen and aid_cast_at
      # @param now [Time]
      # @return [Need, nil]
      def pick(world, roster, name, state, now = Time.now)
        me = world.me
        current = needs(world, roster, name)
        state.aid_seen.select! { |key, _| current.include?(key) }
        state.aid_cast_at.reject! { |_, at| now - at > 60 }
        current.each do |key|
          next if state.aid_seen.key?(key)

          state.aid_seen[key] = now
          Events.emit(:aid_seen, victim: key[0], need: key[1])
        end
        return nil if me.dead? || me.muckled? || !me.able_to_cast?

        mine = known(world)
        return nil if mine.empty?

        current.each do |victim, kind|
          key = [victim, kind]
          last = state.aid_cast_at[key]
          next if last && now - last < REPEAT[kind]
          next if kind == :stun && cleared?(state, victim, now)

          rank = candidates(world, roster, name, mine, victim, kind).index(name)
          next if rank.nil?

          wait = rank * STAGGER
          wait += SELF_GRACE if SELF_CURABLE.include?(kind) && !(Array(roster.dig(victim, :helps)) & REMEDIES[kind]).empty?
          next if now - state.aid_seen[key] < wait

          spell = REMEDIES[kind].map { |n| world.spell[n] }.find { |s| s&.known? && s.affordable? }
          return Need.new(victim: victim, kind: kind, spell: spell) if spell
        end
        nil
      end
    end
  end

  module Actions
    # Shared pieces of the ecleanse actions: TARGET a hazard, a
    # command read through roundtime (Util.get_res 1777). MANA PULSE is
    # Lich's Mana.pulse; the roundtime wait is Base#settle_rt; the stand
    # is Actions::Stand.
    module CleanseHelpers
      # STAND in the profile's stand_stance (Policy#stand_stance), the
      # stance put back after, as Survival stands.
      #
      # @param stand_stance [String, false, nil] nil or false stands as we are
      # @return [Actions::Result, nil] nil when already standing
      def stand_up(stand_stance)
        return nil if me.standing?

        Stand.new(@world, stand_stance: stand_stance || nil, interrupt: @interrupt).call
      end

      # Lich's CMan.use: the command from the maneuver table, sent after
      # roundtime and confirmed on the maneuver's own result lines (the
      # raw sends matched /.*/, any line at all). nil from Lich means
      # unavailable or unanswered.
      #
      # @param name [String] the maneuver's name or short name
      # @param target [String] the target argument, "" for none
      # @return [Actions::Result] success with :cman and the result line,
      #   else failed with :cman_refused
      def cman_use(name, target = '')
        line = ::Lich::Gemstone::CMan.use(name, target)
        line.is_a?(String) ? Result.new(status: :success, reason: :cman, line: line) : Result.new(status: :failed, reason: :cman_refused)
      rescue StandardError => e
        Result.new(status: :failed, reason: :cman_refused, line: e.message)
      end

      # TARGET the hazard by id (ecleanse); only the "turn your
      # attention" answer counts.
      #
      # @param obj [#id] the loot object
      # @return [Boolean]
      def target_hazard(obj)
        result = send_and_match("target ##{obj.id}", Cleanse::TARGET_ANSWERS, timeout: 2)
        result.success? && result.line =~ Cleanse::TARGET_OK ? true : false
      end

      # Spell Cleave at the hazard when available, else Spell Thieve.
      #
      # @param obj [#id] the loot object
      # @return [Actions::Result, nil] the cman_use Result; nil when
      #   neither maneuver is available
      def cleave_or_thieve(obj)
        if Cleanse::Predicates.can_cleave?(@world)
          cman_use('scleave', "##{obj.id}")
        elsif Cleanse::Predicates.can_thieve?(@world)
          cman_use('sthieve', "##{obj.id}")
        end
      end
    end

    # remove_poison, remove_disease: cast until clear or
    # unaffordable.
    class CleanseAffliction < Base
      include CleanseHelpers

      # Casts before giving up with :still_afflicted.
      MAX_CASTS = 6

      # @param world [World]
      # @param kind [Symbol] :poison or :disease
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, kind:, **opts)
        super(world, **opts)
        @kind = kind
      end

      # Dead, or no spell for the kind, refuses the cleanse.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?

        @spell = @kind == :poison ? Cleanse::Spells.poison(@world) : Cleanse::Spells.disease(@world)
        return :no_spell if @spell.nil?

        :ok
      end

      # MANA PULSE, then cast while afflicted and affordable, MAX_CASTS
      # at most.
      #
      # @return [Actions::Result] success with the kind; failed with
      #   :unaffordable, :interrupted or :still_afflicted
      def perform
        ::Lich::Gemstone::Mana.pulse(@spell)
        return Result.new(status: :failed, reason: :unaffordable) unless @spell.affordable?

        MAX_CASTS.times do
          break unless afflicted? && @spell.affordable?
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          @spell.cast
          settle_rt
        end
        afflicted? ? Result.new(status: :failed, reason: :still_afflicted) : Result.new(status: :success, reason: @kind)
      end

      private

      def afflicted?
        return me.diseased? if @kind == :disease

        me.poisoned? || me.debuff_names.any? { |k| k =~ /Wall of Thorns Poison/ }
      end
    end

    # remove_magical: stand, then channel the dispel open at
    # ourselves once per active dispellable debuff.
    class CleanseMagical < Base
      include CleanseHelpers

      # @param stand_stance [String, nil] the stance to stand in
      def initialize(world, stand_stance: nil, **opts)
        super(world, **opts)
        @stand_stance = stand_stance
      end

      # Dead, or no dispel known, refuses the cleanse.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?

        @spell = Cleanse::Spells.dispel(@world)
        @spell ? :ok : :no_spell
      end

      # One channel-open cast per active DISPELLABLE debuff, standing
      # first, until the spell is unaffordable.
      #
      # @return [Actions::Result] success with :dispelled after any cast,
      #   else failed with :unaffordable
      def perform
        ::Lich::Gemstone::Mana.pulse(@spell)
        cast = 0
        Cleanse::DISPELLABLE.each do |debuff|
          next unless me.debuff_active?(debuff)

          ::Lich::Gemstone::Mana.pulse(@spell)
          stand_up(@stand_stance)
          settle_rt
          break unless @spell.affordable?

          @spell.force_incant('channel open')
          cast += 1
        end
        Result.new(status: cast.positive? ? :success : :failed, reason: cast.positive? ? :dispelled : :unaffordable)
      end
    end

    # remove_grounded: CMAN RETREAT with the target cleared and
    # restored, else Escape Artist for a root.
    class CleanseGrounded < Base
      include CleanseHelpers

      # @param stand_stance [String, nil] the stance to stand in
      def initialize(world, stand_stance: nil, **opts)
        super(world, **opts)
        @stand_stance = stand_stance
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Retreat for each of Rooted and Pressed with the stamina, the
      # target cleared and put back; else Escape Artist for a root.
      #
      # @return [Actions::Result] success with :retreat, the Maneuver's
      #   Result, or failed with :no_means
      def perform
        if Cleanse::Predicates.cman_known?('Retreat')
          done = false
          %w[Rooted Pressed].each do |debuff|
            next unless me.debuff_active?(debuff) && me.stamina >= 11

            settle_rt
            stand_up(@stand_stance)
            settle_rt
            current = me.current_target_id
            send_through_ladder('target clear')
            cman_use('retreat')
            send_through_ladder("target ##{current}") if current
            done = true
          end
          Result.new(status: done ? :success : :failed, reason: done ? :retreat : :no_means)
        elsif me.debuff_active?('Rooted') && Cleanse::Predicates.feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
          Maneuver.new(@world, category: :feat, name: 'escapeartist', escapes: %i[webbed bound], interrupt: @interrupt).call
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end
    end

    # remove_stun: the first means the policy allows, in ecleanse's
    # order: barkskin, berserk, 1040, beseech, then the Stun Maneuvers
    # stances, flee and hide.
    class CleanseStun < Base
      include CleanseHelpers

      # @param world [World]
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # The first means the policy allows: barkskin, berserk, 1040,
      # beseech, then the Stun Maneuvers in an ordinary room. The
      # stance and berserk paths wait up to a minute for the stun to
      # clear.
      #
      # @return [Actions::Result] success naming the means; failed with
      #   :no_means
      def perform
        p = @policy
        spell = @world.spell
        escape_room = Escape.kind_for(@world.room.title)
        if p.use_stunned_barkskin && spell[605]&.known? && !me.cooldown_active?('Barkskin: Commune') && !me.cooldown_active?('Barkskin') && !me.spell_active?(605) && me.blessings_ranks >= 15
          ::Lich::Gemstone::Mana.pulse(spell[605])
          if spell[605].available?
            settle_rt
            send_through_ladder('commune barkskin') if me.stunned?
            return wait_unstunned(:barkskin)
          end
        end
        if !escape_room && p.use_berserk_stunned && Cleanse::Predicates.cman_available?('Berserk')
          spell[9607].cast
          sleep 1
          return wait_while_active(9607, :berserk)
        end
        if p.use_stunned1040 && spell[1040]&.known?
          ::Lich::Gemstone::Mana.pulse(spell[1040])
          if spell[1040].available?
            send_through_ladder('shout 1040')
            return Result.new(status: :success, reason: :shout_1040)
          end
        end
        if p.use_1635 && spell[1635]&.known?
          ::Lich::Gemstone::Mana.pulse(spell[1635])
          if spell[1635].available?
            send_through_ladder('beseech')
            return Result.new(status: :success, reason: :beseech)
          end
        end
        return Result.new(status: :failed, reason: :no_means) if escape_room

        return stunman('stance1') if p.use_stance1 && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 3)
        return stunman('stance2') if p.use_stance2 && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 4)
        return stunman('flee') if p.use_flee && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 5)
        return stunman('hide') if p.use_hide && Cleanse::Predicates.cman_available?('Stun Maneuvers', min_rank: 5) && !me.hidden?

        Result.new(status: :failed, reason: :no_means)
      end

      private

      # stunman_perform through CMan.use, as ecleanse does since 2.2.8
      def stunman(type)
        stunman_stand
        case type
        when 'stance1', 'stance2' then stunman_use(type)
        when 'flee'
          room = @world.room.id
          8.times do
            break if @world.room.id != room || !me.stunned? || interrupted?

            stunman_stand
            stunman_use('flee')
            sleep 0.5
          end
          stunman_use('stance2')
        when 'hide'
          8.times do
            break if me.hidden? || !me.stunned? || interrupted?

            stunman_stand
            stunman_use('hide')
            settle_rt
          end
        end
        wait_unstunned(:"stunman_#{type}")
      end

      def stunman_stand
        4.times do
          break if me.standing? || !me.stunned?

          stunman_use('stand')
          settle_rt
        end
      end

      def stunman_use(arg) = ::Lich::Gemstone::CMan.use('stunman', arg)

      def wait_unstunned(reason)
        deadline = clock_now + 60
        sleep 0.25 while me.stunned? && clock_now < deadline && !interrupted? && !me.dead?
        Result.new(status: :success, reason: reason)
      end

      def wait_while_active(num, reason)
        deadline = clock_now + 60
        sleep 0.5 while me.spell_active?(num) && clock_now < deadline && !interrupted?
        Result.new(status: :success, reason: reason)
      end
    end

    # remove_web_bound: 1040, else berserk, else beseech, else
    # Escape Artist.
    class CleanseWebBound < Base
      include CleanseHelpers

      # @param world [World]
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # SHOUT 1040 when affordable; else berserk (waited out, a minute at
      # most), else BESEECH, else Escape Artist.
      #
      # @return [Actions::Result] success with :shout_1040, :berserk or
      #   :beseech, the Maneuver's Result, or failed with :no_means
      def perform
        spell = @world.spell
        ::Lich::Gemstone::Mana.pulse(spell[1040]) if spell[1040]&.known?
        if spell[1040]&.known? && spell[1040].affordable?
          send_through_ladder('shout 1040')
          Result.new(status: :success, reason: :shout_1040)
        elsif @policy.use_berserk_webbed && Cleanse::Predicates.cman_known?('Berserk') && me.stamina >= 21
          spell[9607].cast
          sleep 1
          deadline = clock_now + 60
          sleep 0.5 while me.spell_active?(9607) && clock_now < deadline && !interrupted?
          Result.new(status: :success, reason: :berserk)
        elsif @policy.use_1635 && spell[1635]&.known? && spell[1635].affordable?
          send_through_ladder('beseech')
          Result.new(status: :success, reason: :beseech)
        elsif Cleanse::Predicates.feat_available?('escapeartist', min_rank: 5) && me.stamina >= 15
          Maneuver.new(@world, category: :feat, name: 'escapeartist', escapes: %i[webbed bound], interrupt: @interrupt).call
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end
    end

    # dispel_cloud, avoid_globe, avoid_webs: TARGET the
    # hazard (a refusal marks it bad), then the dispel, else Spell Cleave
    # or Thieve. The acidic mist takes the breeze spell instead.
    class CleanseHazard < Base
      include CleanseHelpers

      # @param world [World]
      # @param kind [Symbol] :cloud, :globe or :web
      # @param object [#id, #name] the hazard in the room's loot
      # @param state [Cleanse::State] takes the refused id
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, kind:, object:, state:, policy:, **opts)
        super(world, **opts)
        @kind = kind
        @object = object
        @state = state
        @policy = policy
      end

      # Dead, or the hazard no longer in the loot, refuses the job.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :gone unless Array(@world.room.loot).any? { |l| l.id.to_s == @object.id.to_s }

        :ok
      end

      # TARGET first (not for the mist or the two untargetable globes),
      # then the breeze at the mist, the dispel at the hazard, or Spell
      # Cleave or Thieve.
      #
      # @return [Actions::Result] success with :breeze, :dispelled or
      #   :cleaved; failed with :untargetable, :no_means or :unaffordable
      def perform
        acid = @kind == :cloud && @object.name.to_s == 'cloud of acidic mist'
        spell = @kind == :web ? Cleanse::Spells.webs(@world) : Cleanse::Spells.dispel(@world)
        able = Cleanse::Casting.able?(@world, @policy)
        unless acid || (@object.name.to_s =~ /silvery blue globe|spiraling ghostly rift/)
          unless target_hazard(@object)
            @state.bad_target!(@object.id)
            return Result.new(status: :failed, reason: :untargetable)
          end
        end

        if acid
          breeze = Cleanse::Spells.breeze(@world)
          return Result.new(status: :failed, reason: :no_means) unless breeze && able && breeze.affordable?

          breeze.num == 912 ? breeze.force_incant : breeze.cast("at ##{@object.id}")
          Result.new(status: :success, reason: :breeze)
        elsif spell && able
          ::Lich::Gemstone::Mana.pulse(spell)
          return Result.new(status: :failed, reason: :unaffordable) unless spell.affordable?

          spell.cast("at ##{@object.id}")
          Result.new(status: :success, reason: :dispelled)
        else
          # cleave_or_thieve answers nil when neither Spell Cleave nor Spell
          # Thieve is available at perform time, and a failed Result when the
          # game refuses the maneuver. Reporting :cleaved either way recorded
          # a hazard as cleansed that is still in the room, and hid a stuck
          # one from the repeated-failures watchdog.
          result = cleave_or_thieve(@object)
          return Result.new(status: :failed, reason: :no_means) if result.nil?

          result.success? ? Result.new(status: :success, reason: :cleaved) : result
        end
      end
    end

    # avoid_runestone: TARGET it, then ATTACK until it shatters, five
    # swings at most.
    class CleanseRunestone < Base
      include CleanseHelpers
      include CombatRt

      # @param world [World]
      # @param object [#id] the runestone in the room's loot
      # @param state [Cleanse::State] takes the refused id
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, object:, state:, **opts)
        super(world, **opts)
        @object = object
        @state = state
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # TARGET, then ATTACK by id until it shatters or leaves the loot,
      # five swings at most.
      #
      # @return [Actions::Result] success with :shattered or
      #   :runestone_done; failed with :untargetable or :interrupted
      def perform
        unless target_hazard(@object)
          @state.bad_target!(@object.id)
          return Result.new(status: :failed, reason: :untargetable)
        end

        5.times do
          settle_rt
          result = send_and_match("attack ##{@object.id}", /It crashes to the ground and shatters into pale dust|^Roundtime|What were you referring to/, timeout: 3)
          return Result.new(status: :success, reason: :shattered) if result.success? && result.line =~ /shatters/
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          break unless Array(@world.room.loot).any? { |l| l.id.to_s == @object.id.to_s }
        end
        Result.new(status: :success, reason: :runestone_done)
      end
    end

    # bigshot cmd_1040 on ourselves: MANA PULSE when 1040 is known
    # but unaffordable, then one cast; the engine ticks again while the
    # ailment holds, which is bigshot's until-clear loop.
    #
    # @bigshot cmd_1040
    class CleanseRally < Base
      include CleanseHelpers

      # Dead, or 1040 unknown, refuses the rally.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :unknown_spell unless @world.spell[1040]&.known?

        :ok
      end

      # Roundtime, MANA PULSE, one cast of 1040.
      #
      # @return [Actions::Result] success with :rally_1040; failed with
      #   :unaffordable
      def perform
        s = @world.spell[1040]
        settle_rt
        # bigshot pulses first and casts only when the pulse made 1040
        # affordable (cmd_1040 6277-6279). A pulse the game refuses - mental
        # fatigue, already full, mana control not trained - leaves us exactly
        # where we were, and rally sits ahead of :stun and :web_bound in the
        # reason order, so a rally that cannot act must say it acted on
        # nothing rather than report a failure the watchdog counts.
        ::Lich::Gemstone::Mana.pulse(s)
        return Result.new(status: :skipped, reason: :unaffordable) unless s.affordable?

        s.cast
        Result.new(status: :success, reason: :rally_1040)
      end
    end

    # determination: cast the Sigil of Determination so the next
    # tick's cleanse can be cast through the injuries.
    class CleanseDetermination < Base
      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # One cast of the sigil when affordable.
      #
      # @return [Actions::Result] success with :determination; failed
      #   with :unaffordable
      def perform
        s = @world.spell['Sigil of Determination']
        return Result.new(status: :failed, reason: :unaffordable) unless s && s.affordable?

        s.cast
        Result.new(status: :success, reason: :determination)
      end
    end

    # settle_room: one defensive spell before a recovery, by policy.
    class CleanseSettleRoom < Base
      include CleanseHelpers

      # @param world [World]
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      # Dead, or nothing in the target list, refuses the settle.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :quiet if Array(@world.room.targets).empty?

        :ok
      end

      # The first the policy allows: 140, 619, 709 (not against
      # appendages), 919, 9811.
      #
      # @return [Actions::Result] success with :settled; failed with
      #   :cannot_cast, :unaffordable or :no_means
      def perform
        p = @policy
        spell = @world.spell
        return Result.new(status: :failed, reason: :cannot_cast) unless Cleanse::Casting.able?(@world, p)

        if p.use_140 && spell[140]&.known? && !me.effect_active?('Wall of Force') && !me.cooldown_active?('Wall of Force')
          cast(spell[140])
        elsif p.use_619 && spell[619]&.known?
          cast(spell[619])
        elsif p.use_709 && spell[709]&.known? && Array(@world.room.creatures).none? { |c| c.noun.to_s =~ Targets::APPENDAGE_NOUNS }
          cast(spell[709])
        elsif p.use_919 && !me.effect_active?("Wizard's Shield") && !me.cooldown_active?("Wizard's Shield")
          cast(spell[919])
        elsif p.use_9811 && spell[9811]&.known?
          spell[9811].cast
          Result.new(status: :success, reason: :settled)
        else
          Result.new(status: :failed, reason: :no_means)
        end
      end

      private

      def cast(s)
        ::Lich::Gemstone::Mana.pulse(s)
        return Result.new(status: :failed, reason: :unaffordable) unless s&.affordable?

        # Sent outside the ladder, so stamp it: the fire budget counts the
        # stamp, not the status, and a settle that repeats every tick is
        # exactly the loop the budget exists to catch.
        @acted = true
        s.cast
        Result.new(status: :success, reason: :settled)
      end
    end

    # recover: back to the disarm room, 213/1011 by policy, the
    # servant when 218 is up, settle the room, defensive, a bonded weapon's
    # own return, else empty hands, kneel, RECOVER ITEM up to ten times,
    # stand, fill hands.
    class CleanseRecover < Base
      include CleanseHelpers

      # RECOVER ITEM tries before giving up.
      SEARCHES = 10
      # The game's answers to RECOVER ITEM.
      RECOVER_ANSWERS = /<dialogData|You spy|You continue to intently search the area|In order to recover something|You find nothing recoverable|You're not in any condition to be searching around/

      # The trip back to the disarm room is the behavior's (a Travel trip
      # before this action runs); here we are in place.
      #
      # @param world [World]
      # @param record [Hash] the State's disarm record: :noun, :known_ids,
      #   :room_id, :title
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # The recovery, start to finish; emits :disarmed first and
      # :cleanse_stuck when the game will not let us search.
      #
      # @return [Actions::Result] success with :servant or :recovered;
      #   failed with :interrupted, :wrong_room, :cannot_search or
      #   :not_recovered
      def perform
        known = @record[:known_ids]
        noun = @record[:noun]
        room_id = @record[:room_id]
        Events.emit(:disarmed, noun: noun, room: room_id, title: @record[:title])
        settle_rt
        stops = cast_213_1011
        if me.spell_active?(218) && servant_recover?
          stops.each { |n| send_through_ladder("stop #{n}") }
          return Result.new(status: :success, reason: :servant)
        end

        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        stance_defensive
        recovered = false
        if bonded?
          deadline = clock_now + 10
          # A waited poll, not a spin: settle_rt returns at once when no
          # roundtime is pending, so this loop yielded nothing and pinned a
          # core for the whole ten seconds. ecleanse polls with Util.wait_rt,
          # which is 0.4 s of sleep per pass (ecleanse).
          settle_rt
          sleep 0.25 until recovered?(known, noun) || clock_now > deadline || interrupted?
          recovered = recovered?(known, noun)
        end
        unless recovered
          send_through_ladder('stow all')
          SEARCHES.times do
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            # The trip to the disarm room is the behavior's, made by the
            # job that wraps this action; being here is the precondition
            # for searching, not something to fix mid-search. This used to
            # call an @travel that Base never sets, so whenever go2 landed
            # a room short - or the room id was briefly nil - the search
            # raised NoMethodError on nil and the engine stopped.
            return Result.new(status: :failed, reason: :wrong_room) if room_id && @world.room.id != room_id

            kneel
            settle_rt
            lines = command_lines('recover item', RECOVER_ANSWERS)
            if lines.any? { |l| l =~ /You spy (?:an|a) (?:.*) and recover it!/ } || recovered?(known, noun)
              recovered = true
              break
            end
            if lines.any? { |l| l =~ /You're not in any condition to be searching around/ }
              stand_up(@policy.stand_stance)
              stops.each { |n| send_through_ladder("stop #{n}") }
              Events.emit(:cleanse_stuck, reason: "Unable to search; #{noun} is in room #{room_id}")
              return Result.new(status: :failed, reason: :cannot_search)
            end
            send_through_ladder('stow all') if lines.any? { |l| l =~ /In order to recover something/ }
          end
          settle_rt
        end
        stand_up(@policy.stand_stance)
        settle_rt
        fill_hands
        stops.each { |n| send_through_ladder("stop #{n}") }
        Result.new(status: recovered ? :success : :failed, reason: recovered ? :recovered : :not_recovered)
      end

      private

      def cast_213_1011
        stops = []
        return stops unless Cleanse::Casting.able?(@world, @policy)

        [[213, @policy.use_213], [1011, @policy.use_1011]].each do |num, on|
          s = @world.spell[num]
          next unless on && s&.known?

          ::Lich::Gemstone::Mana.pulse(s)
          s.cast if s.affordable?
          stops << num
        end
        settle_rt
        stops
      end

      def servant_recover?
        15.times do
          break if Array(@world.room.creatures).any? { |c| c.noun.to_s =~ /spirit/i }

          sleep 0.1
        end
        result = send_and_match('tell servant recover', /flickers for a moment and manifests|has no personal recollection/, timeout: 5)
        result.success? && result.line =~ /flickers for a moment and manifests/
      end

      # recovered?: a hand holds an item that was not there at the
      # disarm, with the disarmed noun when known.
      def recovered?(known_ids, noun)
        [@world.hands.right, @world.hands.left].any? do |h|
          next false if h.nil? || h.id.nil? || h.name.to_s == 'Empty' || known_ids.include?(h.id.to_s)

          noun.nil? || h.noun.to_s.casecmp?(noun.to_s)
        end
      end

      # ecleanse calls Feat.weapon_bonding, which does not exist: Feat
      # exposes [], known?, affordable?, available? and use, and defines no
      # method_missing (psms/feat.rb 294-309). The call raised NoMethodError
      # on every character, the rescue swallowed it, and the rank-5 path was
      # unreachable - a bonded weapon with no 1625 was never recognised.
      # >= 5, not == 5: the rank can go past it.
      def bonded?
        ::Lich::Gemstone::Feat.known?('weapon_bonding', min_rank: 5) || @world.spell[1625]&.known? || false
      rescue StandardError
        # PSMS.assess raises ArgumentError on a name it does not carry.
        @world.spell[1625]&.known? || false
      end

      def kneel
        3.times do
          break if me.kneeling?

          send_and_match('kneel', /You kneel|You are already/i, timeout: 2)
        end
      end

      # Lich's Stance.change answers false when the stance did not take
      # (roundtime, a refusal); a raw STANCE resend on top of it hid why.
      def stance_defensive
        ::Lich::Gemstone::Stance.change('defensive')
      end

      def fill_hands
        ::Lich::Stash.equip_hands(both: true)
      rescue StandardError
        nil
      end

      # Util.get_command: the command's lines, re-sent through roundtime
      def command_lines(command, regex)
        ::Lich::Util.issue_command(command, Regexp.union(regex, /(?:\.\.\.wait) (\d+) [Ss]ec(?:onds)?\./), timeout: 5)
      rescue StandardError
        []
      end
    end

    # recover_weapon_webbing: PRY the weapon free, ten tries.
    class CleansePry < Base
      include CleanseHelpers

      # @param world [World]
      # @param record [Hash] the State's disarm record; :noun is pried
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Settle the room, then PRY MY <noun> until it comes free or the
      # game asks "Pry what", ten tries.
      #
      # @return [Actions::Result] success with :pried; failed with
      #   :interrupted or :still_webbed
      def perform
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        10.times do
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          result = send_and_match("pry my #{@record[:noun]}", /^Pry what|^You try to pry your|^You pry your.*free from the webbing/, timeout: 3)
          return Result.new(status: :success, reason: :pried) if result.success? && result.line =~ /You pry your|Pry what/i
        end
        Result.new(status: :failed, reason: :still_webbed)
      end
    end

    # telekinetic_recover: the dispel at the floating weapon, else
    # GET it, until a hand holds it.
    class CleanseTelekinetic < Base
      include CleanseHelpers

      # @param world [World]
      # @param record [Hash] the State's disarm record: :noun, :known_ids
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, record:, policy:, **opts)
        super(world, **opts)
        @record = record
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Settle the room, then six rounds of the dispel at the weapon (or
      # GET it), stopping when a hand holds it.
      #
      # @return [Actions::Result] success with :recovered; failed with
      #   :interrupted or :not_recovered
      def perform
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        noun = @record[:noun]
        known = @record[:known_ids]
        spell = Cleanse::Spells.dispel(@world)
        6.times do
          return Result.new(status: :success, reason: :recovered) if [@world.hands.right, @world.hands.left].any? { |h| h&.id && !known.include?(h.id.to_s) && h.noun.to_s.casecmp?(noun.to_s) }
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          if spell
            ::Lich::Gemstone::Mana.pulse(spell)
            spell.cast("at #{noun}") if spell.affordable?
          else
            send_through_ladder("get #{noun}")
          end
          settle_rt
        end
        Result.new(status: :failed, reason: :not_recovered)
      end
    end

    # sanctum_recover: CLENCH the transformed weapon back.
    class CleanseSanctum < Base
      include CleanseHelpers

      # @param world [World]
      # @param creature [String, nil] the transforming creature's noun
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, creature:, policy:, **opts)
        super(world, **opts)
        @creature = creature
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # Settle the room, then CLENCH <creature> until the game answers,
      # six tries.
      #
      # @return [Actions::Result] success with :clenched; failed with
      #   :interrupted or :not_clenched
      def perform
        settle_rt
        CleanseSettleRoom.new(@world, policy: @policy, interrupt: @interrupt).call
        6.times do
          result = send_and_match("clench #{@creature}", /You reach up and grab|I could not find what you were referring to\./, timeout: 3)
          settle_rt
          return Result.new(status: :success, reason: :clenched) if result.success?
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :failed, reason: :not_clenched)
      end
    end

    # hive_traps_apparatus, hive_traps_ground: SEARCH until the
    # trap resolves, then DISARM APPARATUS; three of each, twenty seconds.
    class CleanseHiveTrap < Base
      include CleanseHelpers

      # SEARCHes, and DISARMs, before giving up.
      ATTEMPTS = 3
      # Seconds allowed for the searches, and again for the disarms.
      DEADLINE = 20
      # The game's answers to SEARCH.
      SEARCH = /d100: |You don't find anything of interest here|You can't see well enough to search around/
      # The game's answers to DISARM APPARATUS.
      DISARM = /d100: |You want to disarm what\?|You can't see well enough/

      # @param world [World]
      # @param kind [Symbol] :apparatus (search, then disarm) or :ground
      #   (search only)
      # @param state [Cleanse::State] carries and clears hive_trap_room
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, kind:, state:, **opts)
        super(world, **opts)
        @kind = kind
        @state = state
      end

      # Dead, or not in the room the trap was seen in, refuses the job.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :moved unless @state.hive_trap_room && @world.room.id == @state.hive_trap_room

        :ok
      end

      # SEARCH until the trap resolves; a found apparatus gets DISARM
      # APPARATUS. The trap room is forgotten unless we moved or were
      # muckled.
      #
      # @return [Actions::Result] always success, the reason being the
      #   search's outcome: :found, :clear, :blind, :moved, :muckled,
      #   :timeout, :interrupted or :exhausted
      def perform
        result = search
        if result == :found && @kind == :apparatus
          deadline = clock_now + DEADLINE
          ATTEMPTS.times do
            break if @world.room.id != @state.hive_trap_room || me.dead? || me.muckled? || clock_now > deadline || interrupted?

            settle_rt
            lines = command_lines('disarm apparatus', DISARM)
            break if lines.any? { |l| l =~ /Success!|You want to disarm what\?/ }
          end
        end
        @state.hive_trap_room = nil unless %i[moved muckled].include?(result)
        settle_rt
        Result.new(status: :success, reason: result)
      end

      private

      def search
        deadline = clock_now + DEADLINE
        ATTEMPTS.times do
          return :moved if @world.room.id != @state.hive_trap_room
          return :muckled if me.dead? || me.muckled?
          return :timeout if clock_now > deadline
          return :interrupted if interrupted?

          settle_rt
          lines = command_lines('search', SEARCH)
          return :blind if lines.any? { |l| l =~ /You can't see well enough to search around/ }
          return :clear if lines.any? { |l| l =~ /You don't find anything of interest here/ }
          return :found if lines.any? { |l| l =~ /Success!/ }
        end
        :exhausted
      end

      def command_lines(command, regex)
        ::Lich::Util.issue_command(command, Regexp.union(regex, /(?:\.\.\.wait) (\d+) [Ss]ec(?:onds)?\./), timeout: 5)
      rescue StandardError
        []
      end
    end

    # itchy_curse: in the safe room (the profile's, else the nearest
    # town or sanctuary), empty hands, wait out the rash. The trips there
    # and back are the behavior's, around this action.
    class CleanseItchyCurse < Base
      include CleanseHelpers

      # The line that ends the wait.
      RASH_GONE = /You no longer feel so defenseless and the rash seems to disappear\./

      # Where to wait it out: a room id, a map tag, or nil for none.
      #
      # @param world [World] answers nearest_safe_room
      # @param policy [Cleanse::Policy] its safe_room, "" for the nearest
      # @return [Integer, String, nil]
      def self.safe_room(world, policy)
        return policy.safe_room.to_i if policy.safe_room.to_s =~ /\A\d+\z/
        return policy.safe_room unless policy.safe_room.to_s.empty?

        world.nearest_safe_room
      rescue StandardError
        nil
      end

      # @param world [World]
      # @param policy [Cleanse::Policy]
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, policy:, **opts)
        super(world, **opts)
        @policy = policy
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # STOW ALL, then read lines for RASH_GONE up to three minutes;
      # hands are filled again either way.
      #
      # @return [Actions::Result] success with :rash_gone; failed with
      #   :rash_timeout
      def perform
        send_through_ladder('stow all')
        deadline = clock_now + 180
        cleared = false
        until clock_now > deadline || interrupted?
          line = next_line
          if line.nil?
            sleep 1
            next
          end
          if line =~ RASH_GONE
            cleared = true
            break
          end
        end
        ::Lich::Stash.equip_hands(both: true) rescue nil
        Result.new(status: cleared ? :success : :failed, reason: cleared ? :rash_gone : :rash_timeout)
      end
    end

    # use_vat: CLEAN VAT at the Sanctum's vat for the infected
    # wound. The trips there and back are the behavior's.
    class CleanseVat < Base
      include CleanseHelpers

      # The Sanctum vat room's server uid (ecleanse use_vat 1587).
      VAT_UID = 4216054

      # The vat room's map id, or nil when the map does not know it.
      #
      # @param world [World] answers uid_ids
      # @return [Integer, nil]
      def self.vat_room(world)
        world.uid_ids(VAT_UID).first
      rescue StandardError
        nil
      end

      # Only death refuses.
      #
      # @return [Symbol] :ok or :dead
      def preconditions = me.dead? ? :dead : :ok

      # CLEAN VAT, any answer accepted, then roundtime.
      #
      # @return [Actions::Result] success with :vat
      def perform
        send_and_match('clean vat', /.*/, timeout: 3)
        settle_rt
        Result.new(status: :success, reason: :vat)
      end
    end

    # Group aid: one cast for a groupmate's need. 108 and the cures go at
    # the victim; 1040 is a room song and goes out as is (bigshot cmd_1040).
    class CleanseAid < Base
      include CleanseHelpers

      # @param world [World]
      # @param need [Cleanse::Aid::Need]
      # @param cleared [#call] -> Boolean, the game said the stun ended
      # @param opts [Hash] Base's keywords (interrupt)
      def initialize(world, need:, cleared: -> { false }, roster: -> { {} }, **opts)
        super(world, **opts)
        @need = need
        @cleared = cleared
        @roster = roster
      end

      # Dead, or the groupmate already over it, refuses the cast.
      #
      # @return [Symbol] :ok, or the gate that refused
      def preconditions
        return :dead if me.dead?
        return :recovered unless still_needed?

        :ok
      end

      # Look again after the roundtime, then one cast.
      #
      # @return [Actions::Result] success with :aid_<kind>; skipped with
      #   :recovered or :unaffordable
      def perform
        return Result.new(status: :skipped, reason: :recovered) unless still_needed?

        s = @need.spell
        return Result.new(status: :skipped, reason: :unaffordable) unless s.affordable?

        Events.emit(:aid_cast, victim: @need.victim, need: @need.kind, spell: s.num)
        s.num == 1040 ? s.cast : s.cast("at #{@need.victim}")
        Result.new(status: :success, reason: :"aid_#{@need.kind}")
      end

      private

      # A room-seen need holds while the room still shows it; a reported
      # one is trusted until the report changes.
      def still_needed?
        re = { stun: Cleanse::Aid::STUN, muckled: Cleanse::Aid::MUCKLED }[@need.kind]
        # Poison and disease show only in the victim's report: read the
        # latest after the roundtime wait, in case another member cured it.
        return reported_ailing? if re.nil?
        return false if @need.kind == :stun && @cleared.call

        p = Array(@world.room.players).find { |pl| pl.noun.to_s == @need.victim }
        !p.nil? && p.status.to_s =~ re ? true : false
      end

      def reported_ailing?
        entry = @roster.call[@need.victim]
        Array(entry && entry[:ailments]).any? { |a| a.to_sym == @need.kind }
      end
    end
  end

  module Behaviors
    # Priority 5: after Survival, before Flee.
    #
    # Three queued jobs travel: the disarm recovery (back to the disarm
    # room), the itchy curse (to a safe room and back) and the vat (to the
    # Sanctum and back). Each is a Job of stages, one Travel trip tick or
    # one action per engine tick, so the trip is supervised, suspended
    # when Survival takes control, and never blocks the loop.
    class Cleanse < Behavior
      # The run's State, the condition found by the last wants_control?,
      # and the travelling Job in progress, if any.
      #
      # @return [EO::Engine::Cleanse::State, Symbol, nil, Job, nil]
      attr_reader :state, :reason, :job

      # A travelling job: go (to +dest+, skipped when nil or already
      # there), act (+action+ built there), return (to +home+, when set
      # and not there). The act's Result is the job's; a trip that fails
      # ends the job with :could_not_reach.
      Job = Struct.new(:name, :dest, :home, :action, :stage, :result, keyword_init: true)

      # @param policy [EO::Engine::Cleanse::Policy]
      # @param state [EO::Engine::Cleanse::State] fresh unless given
      # @param travel [#call] (room) -> Trip or Boolean; default a Travel trip
      # @param aid [EO::Engine::Cleanse::Aid::Link, nil] the group's roster,
      #   for helping groupmates; nil alone or with group aid off
      def initialize(policy:, state: EO::Engine::Cleanse::State.new, travel: nil, aid: nil)
        super()
        @policy = policy
        @aid = aid
        @state = state
        @travel = travel || EO::Engine::Travel.default
        @trip = nil
        @job = nil
        install
      end

      # After Survival, before Flee.
      #
      # @return [Integer] 5
      def priority = 5

      # The way out of a muckle: this one runs while muckled.
      def runs_muckled? = true

      # The engine's stop: end a trip in flight, drop the job.
      #
      # @return [void]
      def cancel!
        EO::Engine::Travel.cancel(self)
        @job = nil
      end

      # Another behavior took control: hold the trip; the job resumes.
      #
      # @param _world [World] unused
      # @return [void]
      def preempted!(_world) = EO::Engine::Travel.suspend(self)

      # A job is in progress, or a condition holds; the reason is kept
      # for the tick.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        return true if @job

        @reason = EO::Engine::Cleanse::Predicates.reason(world, @policy, @state, aid: @aid)
        !@reason.nil?
      end

      # One step of the job in progress; else one action for the reason,
      # or the next queued line event, between :cleansing and :cleansed.
      #
      # @param world [World]
      # @return [Actions::Result, nil] nil while a job's trip is underway
      #   or nothing applied
      def tick(world)
        return step_job(world) if @job

        reason = @reason || EO::Engine::Cleanse::Predicates.reason(world, @policy, @state, aid: @aid)
        return nil if reason.nil?

        Events.emit(:cleansing, reason: reason)
        result = reason == :queued ? run_queued(world, @state.queue.shift) : run_condition(world, reason)
        Events.emit(:cleansed, reason: reason, result: result&.reason) if result && @job.nil?
        result
      end

      private

      def start_job(world, name:, dest:, home:, &action)
        @job = Job.new(name: name, dest: dest, home: home, action: action, stage: :go)
        step_job(world)
      end

      def step_job(world)
        job = @job
        case job.stage
        when :go
          # A trip in flight is stepped to its end even once the room
          # matches: go2 is still restoring gear after arrival, and a trip
          # left on the holder would be the one the return stage ticked,
          # reporting "arrived home" from the far room.
          if job.dest && (@trip || world.room.id != job.dest)
            outcome = EO::Engine::Travel.step(self, @travel, job.dest, world)
            return nil if outcome == :underway
            # a blocking attempt that did not arrive, or a Trip's attempts
            # spent: the job never runs in the wrong room
            return end_job(Actions::Result.new(status: :failed, reason: :could_not_reach)) unless outcome == :arrived
          end
          job.stage = :act
          step_job(world)
        when :act
          job.result = job.action.call(world)
          Events.emit(:cleansed, reason: job.name, result: job.result&.reason)
          job.stage = :return
          return end_job(job.result) if job.home.nil? || world.room.id == job.home

          nil
        when :return
          outcome = EO::Engine::Travel.step(self, @travel, job.home, world)
          return nil if outcome == :underway

          Events.emit(:cleanse_stuck, reason: "Could not return to #{job.home} after #{job.name}") unless outcome == :arrived
          end_job(job.result)
        end
      end

      def end_job(result)
        @job = nil
        result
      end

      def run_condition(world, reason)
        p = @policy
        case reason
        when :poison then Actions::CleanseAffliction.new(world, kind: :poison).call
        when :disease then Actions::CleanseAffliction.new(world, kind: :disease).call
        when :stun then Actions::CleanseStun.new(world, policy: p).call
        when :web_bound then Actions::CleanseWebBound.new(world, policy: p).call
        when :grounded then Actions::CleanseGrounded.new(world, stand_stance: p.stand_stance).call
        when :magical then Actions::CleanseMagical.new(world, stand_stance: p.stand_stance).call
        # The hazard predicates run a second time here, after
        # wants_control? already saw one: the object can leave the room
        # in between (it was looted, it expired, another hunter took it),
        # and every one of them answers nil when it is gone. The actions
        # dereference the object's id in their own preconditions, so a
        # nil used to raise NoMethodError straight out of the tick.
        when :cloud then hazard(world, p, :cloud, EO::Engine::Cleanse::Predicates.cloud(world, @state))
        when :globe then hazard(world, p, :globe, EO::Engine::Cleanse::Predicates.globe(world, @state))
        when :web then hazard(world, p, :web, EO::Engine::Cleanse::Predicates.web(world, @state))
        when :runestone
          stone = EO::Engine::Cleanse::Predicates.runestone(world, @state)
          stone && Actions::CleanseRunestone.new(world, object: stone, state: @state).call
        when :determination then Actions::CleanseDetermination.new(world).call
        when :rally then Actions::CleanseRally.new(world).call
        when :rally_member
          @state.rally_member_at = Time.now
          Actions::CleanseRally.new(world).call
        when :aid
          need = @state.aid_need
          @state.aid_cast_at[[need.victim, need.kind]] = Time.now
          state = @state
          aid = @aid
          Actions::CleanseAid.new(world, need: need, cleared: -> { EO::Engine::Cleanse::Aid.cleared?(state, need.victim) },
                                         roster: -> { aid.roster }).call
        end
      end

      # One hazard action, or nil when the object it named has left the
      # room since wants_control? saw it. nil is a silent tick: Cleanse
      # re-derives the reason next tick like every other behavior.
      #
      # @param world [World]
      # @param policy [Cleanse::Policy]
      # @param kind [Symbol] :cloud, :globe or :web
      # @param object [Object, nil] the loot the predicate found, or nil
      # @return [Actions::Result, nil]
      def hazard(world, policy, kind, object)
        return nil if object.nil?

        Actions::CleanseHazard.new(world, kind: kind, object: object, state: @state, policy: policy).call
      end

      # The line-driven events (set_hooks 1618), each a queued job.
      def run_queued(world, event)
        p = @policy
        case event[:event]
        when :recover
          record = @state.recover.delete(event[:key])
          return nil unless record

          start_job(world, name: :recover, dest: record[:room_id], home: nil) { |w| Actions::CleanseRecover.new(w, record: record, policy: p).call }
        when :telekinetic_recover
          record = @state.recover.delete(event[:key])
          record ? Actions::CleanseTelekinetic.new(world, record: record, policy: p).call : nil
        when :recover_weapon_webbing
          record = @state.recover.delete(event[:key])
          record ? Actions::CleansePry.new(world, record: record, policy: p).call : nil
        when :sanctum_recover then p.recover_disarmed ? Actions::CleanseSanctum.new(world, creature: @state.creature, policy: p).call : nil
        when :use_vat
          vat = Actions::CleanseVat.vat_room(world)
          return Actions::Result.new(status: :failed, reason: :no_vat_room) if vat.nil?

          start_job(world, name: :use_vat, dest: vat, home: world.room.id) { |w| Actions::CleanseVat.new(w).call }
        when :hive_traps_apparatus then p.hive_traps_apparatus ? Actions::CleanseHiveTrap.new(world, kind: :apparatus, state: @state).call : nil
        when :hive_traps_ground then p.hive_traps_ground ? Actions::CleanseHiveTrap.new(world, kind: :ground, state: @state).call : nil
        when :itchy_curse
          return nil unless p.itchy_curse

          safe = Actions::CleanseItchyCurse.safe_room(world, p)
          return Actions::Result.new(status: :failed, reason: :no_safe_room) if safe.nil?

          start_job(world, name: :itchy_curse, dest: safe, home: world.room.id) { |w| Actions::CleanseItchyCurse.new(w, policy: p).call }
        when :remove_web_bound then Actions::CleanseWebBound.new(world, policy: p).call
        end
      end

      def install
        state = @state
        policy = @policy
        Events.on(:disarm_seen) do |e|
          next unless policy.recover_disarmed

          key = state.record_disarm(e.data[:noun], e.data[:hands], e.data[:room_id], e.data[:title])
          state.enqueue(event: e.data[:kind], key: key)
        end
        Events.on(:sanctum_transform) { |e| state.creature = e.data[:noun]; state.enqueue(event: :sanctum_recover) }
        Events.on(:infected_wound) { state.enqueue(event: :use_vat) }
        Events.on(:hive_trap) { |e| state.hive_trap_room = e.data[:room_id]; state.enqueue(event: e.data[:kind]) }
        Events.on(:itchy_curse) { state.enqueue(event: :itchy_curse) }
        Events.on(:entangled) { state.enqueue(event: :remove_web_bound) }
        return unless @aid

        Watch.on(EO::Engine::Cleanse::Aid::CLEARED, :aid_cleared) { |m| { victim: m[1] } }
        Events.on(:aid_cleared) { |e| state.aid_cleared[e.data[:victim]] = Time.now }
      end
    end
  end
end
