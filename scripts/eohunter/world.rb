# frozen_string_literal: true

# ============================================================================
# world (from forge world.rb)
# ============================================================================

#
# EO::Engine::World - read-only facade over Lich's parsed game state.
#
# The single seam between behaviors/actions and Lich globals (XMLData,
# GameObj, Status, Effects, Spell, Stats/Skills, Map). Behaviors read the
# world fresh each tick and never touch the globals directly; specs stub
# the private source accessors (xmldata/gameobj/...) to fake any state.
#
# Rules:
#   - Read-only. Nothing here sends commands or mutates game state.
#   - No text parsing. If a fact isn't derivable from Lich state, it
#     belongs in patterns.rb as an event, not here.
#   - Durable facts live here; momentary facts travel on the event bus.
#
module EO::Engine
  # Read-only facade over Lich's parsed game state: the single seam between
  # behaviors/actions and Lich globals (XMLData, GameObj, Status, Effects,
  # Spell, Stats/Skills, Map). Nothing here sends commands or parses text;
  # specs stub the source accessors (xmldata/gameobj/...) to fake any state.
  class World
    # Rooms no automation can enter: gate StringProcs that cannot be
    # passed by script (e.g. 23339..23379 behind the Alpine Forest
    # spiked gate, whose wayto proc requires a heavy iron key or a
    # table puzzle and bails with `exit` otherwise - go2 fails there
    # too). Lich room ids, loaded once per session from
    # data/forge_campaign/unreachable_rooms.yml:
    #
    #   rooms:  [12345]          # individual ids
    #   ranges: [[23339, 23379]] # inclusive id ranges
    #
    # Filtered at the two choke points every consumer shares - uid_ids
    # (spawn-room resolution) and exits_from (the local step graph) -
    # so cell rooms, hunting areas, wander steps and go2 targets all
    # skip them without each caller knowing why.
    #
    # @return [Array<Integer>] Lich room ids, memoized for the session
    def self.unreachable_rooms
      @unreachable_rooms ||= load_unreachable_rooms
    end

    # Read the block list from DATA_DIR/eohunter/unreachable_rooms.yml,
    # expanding ranges. Empty outside Lich, without the file, or when it
    # is malformed.
    #
    # @return [Array<Integer>] Lich room ids
    def self.load_unreachable_rooms
      return [] unless defined?(::DATA_DIR)

      path = File.join(::DATA_DIR, 'eohunter', 'unreachable_rooms.yml')
      return [] unless File.exist?(path)

      require 'yaml'
      spec = YAML.safe_load_file(path) || {}
      ids = Array(spec['rooms']).map(&:to_i)
      Array(spec['ranges']).each { |pair| ids.concat((pair[0].to_i..pair[1].to_i).to_a) }
      ids.uniq
    rescue StandardError
      # a malformed block list must never keep the engine from starting
      []
    end

    # @param unreachable [Array<Integer>] room ids to treat as impassable;
    #   default the session's block list
    def initialize(unreachable: World.unreachable_rooms)
      @unreachable = Array(unreachable).map(&:to_i)
    end

    # Is this room on the block list.
    # @param lich_id [Integer, #to_i]
    # @return [Boolean]
    def unreachable?(lich_id) = @unreachable.include?(lich_id.to_i)

    # Our character: vitals, position, status, RT, character sheet.
    # @return [Me] one per World
    def me
      @me ||= Me.new(self)
    end

    # The room we stand in: creatures, players, loot, identity.
    # @return [RoomView] one per World
    def room
      @room ||= RoomView.new(self)
    end

    # What we hold.
    # @return [Hands] one per World
    def hands
      @hands ||= Hands.new(self)
    end

    # Names currently supplied by Lich's reloadable message definitions.
    # Read immediately before preparation sends so removed definitions fail closed.
    # @return [Array<Symbol>]
    def message_events = messages.events.map(&:to_sym)

    # Source seam for named message definitions; specs replace it with a fake.
    # @return [Module] Lich's Combat::Messages
    def messages = ::Lich::Gemstone::Combat::Messages

    # The live CreatureInstance behind a room creature, or nil when Lich
    # has none (a bridged bandit, outside Lich). bigshot 5.16's
    # creature_backed? / npc.creature.
    #
    # @param id [String, Integer, nil] the GameObj id
    # @return [Object, nil] the Lich::Gemstone::Creature instance
    def creature(id)
      return nil if id.nil?

      creature_registry[id.to_s]
    rescue StandardError
      nil
    end

    # --- routing (Map Dijkstra) -------------------------------------------

    # Game UID -> lich room ids (a UID can map to several). Ids on the
    # unreachable list are dropped here, so a spawn room behind an
    # impassable gate resolves like an unmapped one and its cell blocks
    # up front instead of failing a trip at the gate.
    #
    # @param uid [Integer, #to_i] the game's room uid
    # @return [Array<Integer>] Lich room ids, empty when unmapped
    def uid_ids(uid)
      map.ids_from_uid(uid.to_i).reject { |id| unreachable?(id) }
    rescue StandardError
      []
    end

    # The nearest of +ids+ that is actually REACHABLE from here, or nil
    # when none of them are. Mapdb Dijkstra decides, so this answers the
    # question before we walk anywhere - the same check tags.lic makes
    # at the top of its crawl loop. Picking a target by raw distance
    # instead means discovering unreachability by failing at it, one go2
    # attempt per room.
    #
    # @param ids [Array<Integer>] candidate Lich room ids
    # @return [Integer, nil] the nearest reachable id
    def nearest_reachable(ids)
      current = map.current
      return nil unless current

      current.find_nearest(Array(ids).map(&:to_i))
    rescue StandardError
      nil
    end

    # --- local graph (single-step movement) -------------------------------

    # Adjacency for one room: `{neighbour_lich_id => way}`, where way is a
    # direction string or a StringProc to call. Edges whose timeto is a
    # StringProc evaluating to nil are gates we cannot pass right now
    # ("you must lie down", locked doors) and are omitted - the same
    # filter bigshot applies before choosing a step.
    #
    # @param lich_id [Integer] the room to leave
    # @return [Hash{Integer => String, StringProc}] empty when unmapped
    def exits_from(lich_id)
      room = map[lich_id]
      return {} unless room

      room.wayto.each_with_object({}) do |(dest, way), acc|
        next if unreachable?(dest)
        next unless passable?(room, dest)

        acc[dest.to_i] = way
      end
    rescue StandardError
      {}
    end

    # The first game uid the map lists for a room.
    # @param lich_id [Integer]
    # @return [Integer, nil] 0 when the room has no uid, nil when unmapped
    def room_uid(lich_id)
      # &. then .to_i turned the unmapped case into 0, which is the value
      # the doc reserves for a real room, and the rescue could never fire
      # because nothing raised. Keep nil meaning "not on the map".
      uid = map[lich_id]&.uid&.first
      uid&.to_i
    rescue StandardError
      nil
    end

    # The map's location name for a room ("Wehnimer's Landing"); nil when
    # unknown. Wander::Area reports where an unbounded area crosses one.
    #
    # @param lich_id [Integer]
    # @return [String, nil]
    def room_location(lich_id)
      map[lich_id]&.location
    rescue StandardError
      nil
    end

    # --- the bounty (Lich's Bounty; bigshot's bounty mode reads) ------------

    # Lich's parsed bounty task, nil when there is none or Bounty is unloaded.
    # @return [Lich::Gemstone::Bounty::Task, nil]
    def bounty_task
      ::Lich::Gemstone::Bounty.current
    rescue StandardError
      nil
    end

    # The raw bounty text (checkbounty), empty when unavailable.
    # @return [String]
    def bounty_text
      checkbounty.to_s
    rescue StandardError
      ''
    end

    # ecleanse itchy_curse: the nearer of the nearest town and the
    # nearest sanctuary, nil when unmapped.
    #
    # @return [Integer, nil] a Lich room id
    def nearest_safe_room
      here = map.current
      return nil if here.nil?

      distances = here.dijkstra.last
      [here.find_nearest_by_tag('town'), here.find_nearest_by_tag('sanctuary')].compact.min_by { |r| distances[r] || Float::INFINITY }
    rescue StandardError
      nil
    end

    # --- hidden creatures -----------------------------------------------------

    # Lich's Overwatch: a creature hid in this room (a "hides" line) and
    # has not shown since.
    # @return [Boolean] false when Overwatch is unavailable
    def hiders?
      ::Lich::Gemstone::Overwatch.hiders? ? true : false
    rescue StandardError
      false
    end

    # Ids the combat dialog lists that no room object answers to
    # (GameObj.hidden_targets): a creature that arrived hidden, a bandit
    # announced there before it attacks. BanditPatrol's detector.
    # @return [Array<String>] GameObj ids
    def hidden_target_ids
      Array(gameobj.hidden_targets).map(&:to_s)
    rescue StandardError
      []
    end

    # --- Voln (Lich's OrderOfVoln reader) -------------------------------------

    # Lich's OrderOfVoln: is the symbol with this spell number affordable
    # at the current favor. A number Voln does not list, or any error,
    # reads as affordable.
    #
    # @param num [Integer, #to_i] the symbol's spell number
    # @return [Boolean]
    def voln_symbol_affordable?(num)
      voln = ::Lich::Gemstone::Societies::OrderOfVoln
      symbol = Array(voln.all).find { |s| s[:spell_number].to_i == num.to_i }
      symbol ? (voln.affordable?(symbol[:short_name]) ? true : false) : true
    rescue StandardError
      true
    end

    # --- stow settings (Lich's StowList) --------------------------------------

    # The game's STOW DEFAULT container as a GameObj, nil when none is
    # set. Lich reads STOW LIST once and revalidates against the worn
    # inventory; the read is sent here only when that check is stale.
    # @return [GameObj, nil]
    def stow_default
      list = ::Lich::Gemstone::StowList
      list.check(silent: true, quiet: true) unless list.valid?
      list.default
    rescue StandardError
      nil
    end

    # --- claim (bigshot bigclaim? 5921) ------------------------------------

    # Lich's Claim: did the room's arrival text say the creatures here are
    # ours. Unknown reads as ours, the way a solo bigshot treats it.
    #
    # Claim lives at Lich::Claim, not under Lich::Gemstone. The wrong
    # constant raised NameError, which the rescue turned into "ours",
    # so claim detection never ran. Only NameError from Claim being
    # unloaded is rescued now, so a real failure is visible again.
    #
    # @bigshot bigclaim?
    # @return [Boolean]
    def claim_mine?
      claim.mine? ? true : false
    rescue NameError
      true
    end

    # Lich's Claim, resolved lazily so this file loads outside Lich.
    # @return [Module] Lich::Claim
    def claim = ::Lich::Claim

    # Nouns of the group's members (bigshot check_for_deaders_prone 3273,
    # group_member_stunned? 5638): Lich's Group.nouns. Empty when solo or
    # unknown.
    #
    # @bigshot check_for_deaders_prone
    # @bigshot group_member_stunned?
    # @return [Array<String>]
    def group_nouns
      Array(::Lich::Gemstone::Group.nouns).map(&:to_s)
    rescue StandardError
      []
    end

    # Lich's Group: is the group open to joiners. Lich sends GROUP once if
    # it has never looked, then reads the status from the feed.
    # @return [Boolean]
    def group_open?
      ::Lich::Gemstone::Group.open? ? true : false
    rescue StandardError
      false
    end

    # The group's leader by noun when it is someone else; nil when we lead
    # or there is no group (Lich's Group.leader is :self or a GameObj).
    # @return [String, nil]
    def group_leader_noun
      leader = ::Lich::Gemstone::Group.leader
      leader.respond_to?(:noun) ? leader.noun.to_s : nil
    rescue StandardError
      nil
    end

    # Disks in the room that belong to nobody in our group: another
    # hunter's sign, even when Claim says the room is ours.
    # @return [Array<GameObj>]
    def foreign_disks
      Array(::Lich::Gemstone::Disk.all) - Array(::Lich::Gemstone::Group.disks)
    rescue StandardError
      []
    end

    private

    def passable?(room, dest)
      cost = room.timeto[dest.to_s]
      cost.is_a?(StringProc) ? cost.call.is_a?(Numeric) : !cost.nil?
    rescue StandardError
      false
    end

    public

    # --- source accessors (the spec seam; override/stub these) -----------
    # Resolved lazily so this file loads outside Lich.

    # Source accessor (the spec seam): Lich's creature registry.
    # @return [Module] Lich::Gemstone::Creature
    def creature_registry = ::Lich::Gemstone::Creature

    # Source accessor (the spec seam): Lich's parsed game state.
    # @return [Object] XMLData
    def xmldata = ::XMLData

    # Lich's mind-state words (global_defs checksaturated / checkfried).
    # Source accessor (the spec seam).
    # @return [Boolean] the mind word is "saturated"
    def saturated? = checksaturated ? true : false
    # Lich's checkfried on the mind word. Source accessor (the spec seam).
    # @return [Boolean]
    def fried?     = checkfried ? true : false

    # Lich's indicator readers (global_defs checkstanding and kin) for
    # posture and the conditions Status has no word for; the muckle
    # states come from Status itself. Source accessors (the spec seam).
    # @return [Boolean] checkstanding
    def standing? = checkstanding ? true : false
    # @return [Boolean] checksitting (the spec seam)
    def sitting?  = checksitting ? true : false
    # @return [Boolean] checkkneeling (the spec seam)
    def kneeling? = checkkneeling ? true : false
    # @return [Boolean] checkprone (the spec seam)
    def prone?    = checkprone ? true : false
    # @return [Boolean] checkhidden (the spec seam)
    def hidden?   = checkhidden ? true : false
    # @return [Boolean] checkpoison (the spec seam)
    def poisoned? = checkpoison ? true : false
    # @return [Boolean] checkdisease (the spec seam)
    def diseased? = checkdisease ? true : false
    # @return [Boolean] checkbleeding (the spec seam)
    def bleeding? = checkbleeding ? true : false

    # Source accessor (the spec seam): Lich's wound table.
    # @return [Module] Wounds
    def wounds_mod = ::Wounds
    # Source accessor (the spec seam): Lich's room and inventory objects.
    # @return [Class] GameObj
    def gameobj = ::GameObj

    # The cached READY LIST item only; never refresh inventory in a predicate.
    # @param slot [Symbol]
    # @return [Object, nil]
    def ready_item(slot)
      list = ::Lich::Gemstone::ReadyList
      list.checked? ? list.ready_list[slot] : nil
    rescue StandardError
      nil
    end

    # Source accessor (the spec seam): Lich's status words.
    # @return [Module] Lich::Gemstone::Status
    def status    = ::Lich::Gemstone::Status
    # Source accessor (the spec seam): Lich's spell list.
    # @return [Class] Spell
    def spell     = ::Spell
    # Source accessor (the spec seam): Lich's stats.
    # @return [Module] Stats
    def stats     = ::Stats
    # Source accessor (the spec seam): Lich's skills.
    # @return [Module] Skills
    def skills    = ::Skills
    # Source accessor (the spec seam): Lich's map.
    # @return [Class] Map
    def map       = ::Map
    # Source accessor (the spec seam): the time source for RT arithmetic.
    # @return [#now] Time
    def clock     = Time
    # Source accessor (the spec seam): Lich's character reader.
    # @return [Module] Char
    def char      = ::Char
    # Source accessor (the spec seam): Lich's experience reader.
    # @return [Module] Lich::Gemstone::Experience
    def experience = ::Lich::Gemstone::Experience
    # Source accessor (the spec seam): Lich's injury tables.
    # @return [Module] Lich::Gemstone::Injured
    def injured    = ::Lich::Gemstone::Injured

    # --- Me: vitals, position, status, RT, character sheet ---------------

    # Our character, read through the World's source accessors: vitals,
    # roundtime, posture, status, effects dialogs, experience, injuries
    # and the character sheet.
    class Me
      # @param world [World] the facade whose accessors this reads
      def initialize(world) = @w = world

      # @return [String] our character name
      def name = @w.char.name.to_s

      # vitals
      # @return [Integer] current health
      def health      = @w.xmldata.health
      # @return [Integer] maximum health
      def max_health  = @w.xmldata.max_health
      # @return [Integer] current mana
      def mana        = @w.xmldata.mana
      # @return [Integer] maximum mana
      def max_mana    = @w.xmldata.max_mana
      # @return [Integer] current stamina
      def stamina     = @w.xmldata.stamina
      # @return [Integer] maximum stamina
      def max_stamina = @w.xmldata.max_stamina
      # @return [Integer] current spirit
      def spirit      = @w.xmldata.spirit
      # @return [Integer] maximum spirit
      def max_spirit  = @w.xmldata.max_spirit

      # @return [Integer] health as a rounded percentage of its maximum
      def health_pct  = pct(health, max_health)
      # @return [Integer] mana as a rounded percentage of its maximum
      def mana_pct    = pct(mana, max_mana)
      # @return [Integer] stamina as a rounded percentage of its maximum
      def stamina_pct = pct(stamina, max_stamina)
      # @return [Integer] spirit as a rounded percentage of its maximum
      def spirit_pct  = pct(spirit, max_spirit)

      # roundtime (seconds remaining; 0.0 when free)
      # @return [Float]
      def rt
        [0.0, @w.xmldata.roundtime_end.to_f - @w.clock.now.to_f + @w.xmldata.server_time_offset.to_f].max
      end

      # Cast roundtime remaining, 0.0 when free.
      # @return [Float] seconds
      def cast_rt
        [0.0, @w.xmldata.cast_roundtime_end.to_f - @w.clock.now.to_f + @w.xmldata.server_time_offset.to_f].max
      end

      # @return [Boolean] roundtime remains
      def in_rt?      = rt.positive?
      # @return [Boolean] cast roundtime remains
      def in_cast_rt? = cast_rt.positive?

      # posture and conditions, through Lich's readers on World
      # @return [Boolean]
      def standing? = @w.standing?
      # @return [Boolean]
      def sitting?  = @w.sitting?
      # @return [Boolean]
      def kneeling? = @w.kneeling?
      # @return [Boolean]
      def prone?    = @w.prone?
      # @return [Boolean]
      def hidden?   = @w.hidden?
      # @return [Boolean]
      def poisoned? = @w.poisoned?
      # @return [Boolean]
      def diseased? = @w.diseased?
      # @return [Boolean]
      def bleeding? = @w.bleeding?

      # The game's current target (TARGET #id), nil when none.
      # @return [String, nil]
      def current_target_id = @w.xmldata.current_target_id

      # @return [Integer] Lich's shadow essence resource count
      def shadow_essence = ::Lich::Resources.shadow_essence.to_i

      # Lich's Status for the muckle states
      # @return [Boolean]
      def dead?     = @w.status.dead?
      # @return [Boolean]
      def stunned?  = @w.status.stunned?
      # @return [Boolean]
      def webbed?   = @w.status.webbed?
      # @return [Boolean]
      def sleeping? = @w.status.sleeping?

      # bigshot reads a bare frozen? (group_status_ailments) that Lich
      # does not define; answered by Status when it grows one, false until.
      #
      # The guard cannot be respond_to?(:frozen?): Object defines frozen?,
      # so that is true of every object and the call resolved to
      # Object#frozen? on the Status module itself - whether the module is
      # literally frozen, never a character state. Ask whether Status
      # declared one of its own instead.
      # @bigshot group_status_ailments
      # @return [Boolean]
      def frozen?
        status = @w.status
        # Kernel#frozen? is inherited by everything, so only a reader Status
        # declared itself counts. Ask who owns the method, not whether one
        # answers.
        owner = status.method(:frozen?).owner
        return false if [::Kernel, ::Object].include?(owner)

        status.frozen? ? true : false
      rescue StandardError
        false
      end

      # @return [Boolean]
      def bound?    = @w.status.bound?
      # @return [Boolean]
      def silenced? = @w.status.silenced?

      # dead || stunned || sleeping || bound || webbed - "can I act at all"
      # @return [Boolean]
      def muckled?  = @w.status.muckled?

      # stance
      # @return [String] the stance word ("offensive", "guarded", ...)
      def stance_text  = @w.xmldata.stance_text
      # @return [Integer] the stance as a 0-100 value
      def stance_value = @w.xmldata.stance_value

      # --- experience (Lich's Experience and XMLData) -------------------
      #
      # The exact numbers, from the game's own experience tags: field
      # experience against its cap, total experience, the count to the
      # next level. The rest thresholds read fxp_pct; the bounty flow
      # gates on the game's mind words.

      # @return [Integer] current field experience
      def fxp        = @w.experience.fxp_current.to_i
      # @return [Integer] the field experience cap
      def fxp_max    = @w.experience.fxp_max.to_i
      # @return [Integer] total experience
      def exp        = @w.experience.exp.to_i
      # @return [Integer] experience to the next level
      def until_next = @w.experience.until_next.to_i

      # The game's mind bar: its word ("clear", "must rest", "saturated")
      # and its 0-100 value.
      # @return [String] the mind word
      def mind_text  = @w.xmldata.mind_text
      # @return [Integer] the mind bar's 0-100 value
      def mind_value = @w.xmldata.mind_value.to_i

      # Lich's checksaturated and checkfried on the mind word.
      # @return [Boolean]
      def saturated?   = @w.saturated?
      # @return [Boolean] Lich's checkfried
      def mind_fried?  = @w.fried?

      # Dialog-backed effect check (Buffs / Active Spells), by name or
      # spell number. Society sigils live in the Buffs dialog where
      # Spell#active? cannot always see them.
      #
      # @param name_or_num [String, Integer]
      # @return [Boolean] false when the dialogs are unavailable
      def effect_active?(name_or_num)
        eff = ::Lich::Gemstone::Effects
        eff::Buffs.active?(name_or_num) || eff::Spells.active?(name_or_num)
      rescue StandardError
        false
      end

      # The Cooldowns dialog ("Multi-Strike" after an mstrike) and the
      # Debuffs dialog ("Overexerted" after over-spending stamina).
      #
      # @param name [String]
      # @return [Boolean] the Cooldowns entry is active
      def cooldown_active?(name)
        ::Lich::Gemstone::Effects::Cooldowns.active?(name)
      rescue StandardError
        false
      end

      # @param name [String]
      # @return [Boolean] the Debuffs entry is active
      def debuff_active?(name)
        ::Lich::Gemstone::Effects::Debuffs.active?(name)
      rescue StandardError
        false
      end

      # Active Spells dialog by name or pattern (bigshot ES"..." 3596).
      #
      # @bigshot ES
      # @param pattern [String, Regexp]
      # @return [Boolean]
      def spell_effect_active?(pattern)
        ::Lich::Gemstone::Effects::Spells.active?(pattern)
      rescue StandardError
        false
      end

      # Any Buffs-dialog entry matching +pattern+ (bigshot).
      #
      # @bigshot,
      # @param pattern [Regexp]
      # @return [Boolean]
      def buff_matching?(pattern)
        ::Lich::Gemstone::Effects::Buffs.to_h.keys.any? { |k| k.to_s =~ pattern }
      rescue StandardError
        false
      end

      # The largest number a Buffs-dialog name matching +pattern+ carries
      # in its first capture ("Empowered (+30)" -> 30), nil when none.
      #
      # @param pattern [Regexp] with one capture group around the number
      # @return [Integer, nil]
      def buff_bonus(pattern)
        ::Lich::Gemstone::Effects::Buffs.to_h.keys.filter_map { |k| k.to_s[pattern, 1]&.to_i }.max
      rescue StandardError
        nil
      end

      # Minutes left on an Active Spells entry and a Cooldowns entry
      # (bigshot cmd_curse 4693, cmd_leech 6065).
      #
      # @bigshot cmd_curse
      # @bigshot cmd_leech
      # @param name [String]
      # @return [Float] minutes, 0.0 when absent
      def spell_effect_time_left(name)
        ::Lich::Gemstone::Effects::Spells.time_left(name).to_f
      rescue StandardError
        0.0
      end

      # Minutes left on a Cooldowns entry.
      # @param name [String]
      # @return [Float] minutes, 0.0 when absent
      def cooldown_time_left(name)
        ::Lich::Gemstone::Effects::Cooldowns.time_left(name).to_f
      rescue StandardError
        0.0
      end

      # Nouns of everything worn or carried (cmd_wield 4573), and one item
      # by a name fragment (cmd_ranged 6357).
      #
      # @bigshot cmd_wield
      # @return [Array<String>]
      def inventory_nouns
        Array(@w.gameobj.inv).map { |i| i.noun.to_s }
      rescue StandardError
        []
      end

      # The first inventory item whose name matches the fragment.
      # @bigshot cmd_ranged
      # @param fragment [String] used as a regex source
      # @return [GameObj, nil]
      def inventory_named(fragment)
        Array(@w.gameobj.inv).find { |i| i.name.to_s =~ /#{fragment}/ }
      rescue StandardError
        nil
      end

      # Minutes left on a Buffs-dialog effect, 0.0 when absent (bigshot
      # cmd_rapid 5070, cast_signs 7390).
      #
      # @bigshot cmd_rapid
      # @bigshot cast_signs
      # @param name [String]
      # @return [Float] minutes
      def buff_time_left(name)
        ::Lich::Gemstone::Effects::Buffs.time_left(name).to_f
      rescue StandardError
        0.0
      end

      # Voln favor (bigshot cast_signs 7475) and Spiritual Lore, Blessings
      # ranks (mstrike_spell_check 5139).
      #
      # @bigshot cast_signs
      # @return [Integer] Voln favor
      def voln_favor = ::Lich::Resources.voln_favor.to_i

      # Lich's OrderOfVoln: is the symbol with this spell number affordable
      # at the current favor. Lich prices it from the per-level cost table
      # and the symbol's modifier; unknown reads as affordable.
      #
      # @param num [Integer] the symbol's spell number
      # @return [Boolean]
      def voln_symbol_affordable?(num) = @w.voln_symbol_affordable?(num)

      # Spiritual Lore, Blessings ranks: what decides how many strikes a
      # blessed weapon has left, and so whether an MSTRIKE is worth spending
      # them before the blessing runs out.
      # @bigshot mstrike_spell_check
      # @return [Integer]
      def blessings_ranks = @w.skills.slblessings.to_i

      # Lich's Injured: do our wounds and scars allow a cast, an active
      # Sigil of Determination counted. Lich may send an _injury query
      # when the injuries changed since it last looked, so this is a
      # decision-point read, not a per-tick one.
      #
      # @return [Boolean]
      def able_to_cast?
        @w.injured.able_to_cast? ? true : false
      end

      # The same tables for HIDE (legs and feet), SEARCH (head, nerves,
      # eyes) and FIRE (arms and hands).
      # @return [Boolean] the injuries allow HIDE
      def able_to_sneak?      = @w.injured.able_to_sneak? ? true : false
      # @return [Boolean] the injuries allow SEARCH
      def able_to_search?     = @w.injured.able_to_search? ? true : false
      # @return [Boolean] the injuries allow FIRE
      def able_to_use_ranged? = @w.injured.able_to_use_ranged? ? true : false

      # Every Debuffs-dialog name (ecleanse main_loop 1849).
      # @return [Array<String>]
      def debuff_names
        ::Lich::Gemstone::Effects::Debuffs.to_h.keys.map(&:to_s)
      rescue StandardError
        []
      end

      # Ids of everything in our inventory (bigshot's bless watch 2362).
      # @bigshot bless watch
      # @return [Array<String>]
      def inventory_ids
        Array(@w.gameobj.inv).map { |i| i.id.to_s }
      rescue StandardError
        []
      end

      # The level a stacking debuff shows in its name, "Creeping Dread (3)"
      # -> 3 (bigshot creeping_dread? 7133). nil when the debuff is absent.
      #
      # @bigshot creeping_dread?
      # @param name [String] the debuff name without its level
      # @return [Integer, nil] 0 when the name carries no level
      def debuff_level(name)
        key = ::Lich::Gemstone::Effects::Debuffs.to_h.keys.find { |k| k.to_s.include?(name) }
        key && key.to_s[/\((\d+)\)/, 1].to_i
      rescue StandardError
        nil
      end

      # Field experience as a percentage of its cap (bigshot check_mind
      # 7100: Experience.percent_fxp).
      # @bigshot check_mind
      # @return [Integer]
      def fxp_pct = @w.experience.percent_fxp.to_i

      # @return [Integer] encumbrance as a percentage (Char.percent_encumbrance)
      def encumbrance_pct = @w.char.percent_encumbrance.to_i

      # character sheet
      # @return [Integer] our level
      def level = @w.stats.level

      # Multi Opponent Combat ranks (bigshot cmd_mstrike 5171: 30 for a
      # focused mstrike, 5 for an unfocused one).
      # @bigshot cmd_mstrike
      # @return [Integer]
      def moc_ranks = @w.skills.multi_opponent_combat.to_i
      # @return [String] our profession
      def profession = @w.stats.profession

      # @return [Array<Spell>] Lich's active spells
      def active_spells = @w.spell.active

      # Nonzero wound ranks by body part - our own wounds change our AS, so
      # they're part of every sample's conditions.
      # @return [Hash{Symbol, String => Integer}] empty when unavailable
      def wounds
        all = @w.wounds_mod.all_wounds
        all.is_a?(Hash) ? all.reject { |_, rank| rank.to_i.zero? } : {}
      rescue StandardError
        {}
      end

      # @return [Array<Integer>] the numbers of the active spells, empty on error
      def active_spell_numbers
        @w.spell.active.map(&:num)
      rescue StandardError
        []
      end

      # Lich's Spell.active? is Spell[val].active?, and Spell[] answers nil
      # for a name it does not know, so an unknown name raised NoMethodError
      # out of this reader - the one Me effect reader without the rescue its
      # neighbours all carry.
      #
      # @param num [Integer, String] a spell number or name
      # @return [Boolean] Spell.active?, false when the spell is unknown
      def spell_active?(num)
        @w.spell[num] ? @w.spell.active?(num) : false
      rescue StandardError
        false
      end

      # @return [String, nil] the spell prepared and not yet cast
      def prepared_spell = @w.xmldata.prepared_spell

      private

      def pct(cur, max)
        return 0 if max.to_i.zero?

        (cur.to_f / max * 100).round
      end
    end

    # --- Room: creatures, players, loot, identity -------------------------

    # The room we stand in, read through the World's source accessors:
    # identity, exits, and GameObj's creatures, players and loot.
    class RoomView
      # @param world [World] the facade whose accessors this reads
      def initialize(world) = @w = world

      # @return [Integer, String] the game's room uid (XMLData.room_id)
      def uid   = @w.xmldata.room_id
      # @return [Integer, nil] the Lich room id, nil when unmapped
      def id    = @w.map.current&.id
      # @return [Array<String>] the map's tags for this room
      def tags  = Array(@w.map.current&.tags)
      # @return [String] the room title
      def title = @w.xmldata.room_title
      # @return [Integer] increments on movement - "did I move" signal
      def count = @w.xmldata.room_count # increments on movement - "did I move" signal
      # @return [String] the obvious exits line
      def exits = @w.xmldata.room_exits
      # Lich's own outside? reads the exits line, not the map: "Obvious
      # paths:" outdoors, "Obvious exits:" indoors (global_defs.rb 1214).
      # Reading it the same way keeps the answer right in an unmapped room.
      # @return [Boolean] the room is outdoors
      def outside? = @w.xmldata.room_exits_string.to_s.include?('Obvious paths:')

      # @return [Array<GameObj>] every npc GameObj lists, dead ones included
      def creatures = Array(@w.gameobj.npcs)
      # The game's own target list: hostile, alive, much noise removed. Targets
      # works from this, never from creatures.
      # @return [Array<GameObj>]
      def targets   = Array(@w.gameobj.targets)
      # @return [Array<GameObj>] the players here
      def players   = Array(@w.gameobj.pcs)
      # @return [Array<GameObj>] the objects on the floor
      def loot      = Array(@w.gameobj.loot)

      # Room objects that hurt whoever stands here, with no attacker to
      # fight back against: bigshot's four flee families (should_flee?
      # 6872-6877), each behind its own profile toggle (flee_clouds,
      # flee_vines, flee_webs, flee_voids). Matched on the object list,
      # never on room description text: "mist" and "fog" are scenery in
      # hundreds of rooms, and treating them as hazards would have us
      # fleeing half the map.
      # @bigshot should_flee?
      HAZARDS = {
        cloud: ->(o) { o.noun.to_s =~ /cloud|breath/ || o.name.to_s == 'intense shimmering circle' },
        vine: ->(o) { o.noun.to_s =~ /vine/ },
        web: ->(o) { o.noun.to_s =~ /web/ },
        void: ->(o) { o.name.to_s =~ /black void/ }
      }.freeze

      # The hazard objects here, from the loot list only.
      #
      # bigshot's should_flee? scans GameObj.loot for these four families
      # and nothing else. It does scan GameObj.npcs immediately below, but
      # for a different thing - the always_flee_from name list, which this
      # engine keeps on Flee::Policy - so creatures never belonged here.
      #
      # Including them made the room permanently hazardous: a vine, web or
      # cloud creature stays on the npc list after it dies, so the flee
      # trigger never cleared and the hunter fled the room for good.
      #
      # @param kinds [Array<Symbol>] which families count, default all
      # @return [Array<GameObj>] the offending objects
      def hazards(kinds: HAZARDS.keys)
        checks = HAZARDS.values_at(*kinds).compact
        loot.select { |o| checks.any? { |check| check.call(o) } }
      end

      # @param kinds [Array<Symbol>] which families count, default all
      # @return [Boolean] any hazard of those families is here
      def hazardous?(kinds: HAZARDS.keys) = hazards(kinds: kinds).any?

      # Creatures we may engage: alive, present, not severed-limb noise.
      # @return [Array<GameObj>]
      def live_creatures
        creatures.reject { |npc| npc.status =~ /dead|gone/ }
      end

      # @param id [String, Integer] a GameObj id
      # @return [GameObj, nil] the creature here with that id
      def creature_by_id(id)
        creatures.find { |npc| npc.id == id.to_s }
      end

      # @return [Boolean] no other players here
      def empty_of_players? = players.empty?
    end

    # --- Hands ------------------------------------------------------------

    # What we hold, read through GameObj's right_hand and left_hand.
    class Hands
      # @param world [World] the facade whose accessors this reads
      def initialize(world) = @w = world

      # Lich returns a GameObj named "Empty" with nil id for an empty hand.
      # @return [GameObj] the right hand's object
      def right = @w.gameobj.right_hand
      # @return [GameObj] the left hand's object ("Empty" with nil id when empty)
      def left  = @w.gameobj.left_hand

      # @return [Boolean]
      def right_empty? = right.id.nil?
      # @return [Boolean]
      def left_empty?  = left.id.nil?
      # @return [Boolean] both hands empty
      def empty?       = right_empty? && left_empty?

      # @param noun_pattern [Regexp] matched against each held object's noun
      # @return [Boolean] either hand holds a matching object
      def holding?(noun_pattern)
        [right, left].any? { |h| h.id && h.noun.to_s =~ noun_pattern }
      end

      # Exist-ids of whatever is held (0-2 entries). Lets a caller diff
      # hands across an action and identify exactly what appeared.
      # @return [Array<String>]
      def held_ids
        [right, left].filter_map { |h| h.id }
      end
    end
  end
end
