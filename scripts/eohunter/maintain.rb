# frozen_string_literal: true

# ============================================================================
# maintain (bigshot's cast_signs, cmd_bless, wrack, check_902_411,
#           mstrike_spell_check)
# ============================================================================

#
# bigshot keeps its buffs up by calling cast_signs before every
# command, before every move and after every step, re-blesses a weapon
# the moment the game says its blessing wore off (cmd_bless 4629, from
# hunt_monitor's two lines), and wracks for mana when a sign or spell is
# unaffordable (wrack 5743). The engine's Maintain is that as a behavior
# at priority 40: one bless or one sign per tick, with every gate bigshot
# applies to each. Rules and bigshot line references in
# hunting-engine-plan.md, "Maintain".
#
module EO::Engine
  # The buff-keeping side of bigshot: the signs policy and state, the
  # sign parser and its due rules, and the stamina top-up for mstrike.
  module Maintain
    # signs / bless / use_wracking / wracking_spirit / check_favor / ammo
    # from the profile.
    #
    # @bigshot profile settings
    # @!attribute signs
    #   @return [Array<String>] the profile's signs list, unparsed
    # @!attribute bless
    #   @return [Boolean] re-bless a weapon whose blessing wore off
    # @!attribute use_wracking
    #   @return [Boolean] wrack for mana when a sign is unaffordable
    # @!attribute wracking_spirit
    #   @return [Integer] the spirit floor under which wracking is refused
    # @!attribute check_favor
    #   @return [Boolean] check favor before the FAVOR_CHECKED symbols
    # @!attribute ammo
    #   @return [String, nil] our ammo's noun, for the shrugged-bless watch
    Policy = Struct.new(:signs, :bless, :use_wracking, :wracking_spirit, :check_favor, :ammo, keyword_init: true) do
      def initialize(signs: [], bless: false, use_wracking: false, wracking_spirit: 0, check_favor: false, ammo: nil) = super
    end

    # What Maintain learned about the wielded weapon and the blessings
    # still wanted; shared with the script so a rest can list them.
    class State
      # @!attribute blessed_902
      #   @return [Boolean] the right hand's item gleams with 902
      # @!attribute blessed_411
      #   @return [Boolean] the right hand's item is surrounded by 411
      # @!attribute adrenal_at
      #   @return [Time, nil] when Adrenal Surge was last cast
      attr_accessor :blessed_902, :blessed_411, :adrenal_at
      # @return [Array<String>] the item ids still wanting a bless, newest last
      attr_reader :bless_wanted

      def initialize
        @blessed_902 = false
        @blessed_411 = false
        @bless_wanted = []
        @adrenal_at = nil
      end
    end

    # One entry of the profile's signs list, read the way cast_signs does.
    #
    # @!attribute entry
    #   @return [String] the raw profile entry, stripped
    # @!attribute kind
    #   @return [Symbol] :assume, :rapid, :shout, :surge, :burst, :channel,
    #     :bless_902, :bless_411 or :spell
    # @!attribute num
    #   @return [Integer] the spell number
    # @!attribute args
    #   @return [Array<String, nil>, nil] the aspects for 650, the rapid fire argument for 515
    Sign = Struct.new(:entry, :kind, :num, :args, keyword_init: true)

    # The signs list parser and the per-sign due rules of cast_signs.
    #
    # @bigshot cast_signs
    module Signs
      # The Voln symbols cast_signs skips while Symbol of Sleep is up.
      VOLN_SYMBOLS = [9903, 9904, 9905, 9906, 9907, 9908, 9909, 9910, 9912, 9913, 9914, 9918].freeze
      # Short buffs with a cooldown of the spell's own name, skipped while it runs.
      SHORT_BUFFS = [140, 211, 215, 219, 240, 919, 1619, 1650].freeze
      # Spells skipped while a differently named cooldown is active.
      COOLDOWN_SKIPS = { 320 => 'Ethereal Censer', 605 => 'Barkskin' }.freeze
      # bigshot: the symbols whose favor is checked before casting.
      # The cost itself is Lich's (OrderOfVoln: the per-level table times
      # the symbol's modifier), not a formula.
      #
      # @bigshot favor check
      FAVOR_CHECKED = [9805, 9806, 9816].freeze

      module_function

      # The profile's signs list as Signs, one per entry, kinds by the
      # patterns cast_signs matches: "650 <aspect> <aspect>", 515 or
      # "rapid(fire)", 122420, 9605, 9625, 909, 902, 411, else a spell
      # number.
      #
      # @param entries [Array<String>, nil] the profile's signs list
      # @return [Array<Sign>] one per entry
      def parse(entries)
        Array(entries).map do |raw|
          entry = raw.to_s.strip
          case entry
          when /\b650\s?(\w+)?\s?(\w+)?\s?/ then Sign.new(entry: entry, kind: :assume, num: 650, args: [Regexp.last_match(1), Regexp.last_match(2)])
          when /\b(?:515|rapid|rapidfire)(?:\s?\(?(\w+)\)?)?/ then Sign.new(entry: entry, kind: :rapid, num: 515, args: [Regexp.last_match(1)])
          when /^122420$/ then Sign.new(entry: entry, kind: :shout, num: 122420)
          when /^9605$/ then Sign.new(entry: entry, kind: :surge, num: 9605)
          when /^9625$/ then Sign.new(entry: entry, kind: :burst, num: 9625)
          when /^909$/ then Sign.new(entry: entry, kind: :channel, num: 909)
          when /^902$/ then Sign.new(entry: entry, kind: :bless_902, num: 902)
          when /^411$/ then Sign.new(entry: entry, kind: :bless_411, num: 411)
          else Sign.new(entry: entry, kind: :spell, num: entry.to_i)
          end
        end
      end

      # Why a sign is due now, or nil: :cast, :wrack (unaffordable and
      # wracking is on), :maneuver, :shout, :channel. cast_signs 7372-7490.
      #
      # @bigshot cast_signs
      # @param world [World]
      # @param sign [Sign] the parsed entry
      # @param policy [Policy] the maintain settings
      # @param state [State] the bless flags
      # @param now [Time] the clock, for the 1.5 s recast gap
      # @param renewal_cost [Integer] a Bard's song renewal cost, 0 otherwise
      # @return [Symbol, nil, false] :cast, :wrack, :maneuver, :shout, :channel, :assume, or nil;
      #   false from the bless kinds when the spell is not ready
      def due(world, sign, policy, state, now: Time.now, renewal_cost: 0)
        me = world.me
        case sign.kind
        when :assume then assume_due?(world, sign) ? :assume : nil
        when :rapid then rapid_due?(world, sign) ? :cast : nil
        when :shout
          return nil unless psm_available?(:warcry, "Seanette's Shout")
          return nil unless me.buff_time_left('Empowered (+20)') <= (10 / 60.to_f)
          return nil if me.stamina < 25

          :shout
        when :surge then cman_due?(me, 'Surge of Strength')
        when :burst then cman_due?(me, 'Burst of Swiftness')
        when :channel
          s = world.spell[909]
          s && s.known? && s.affordable? && !s.active? ? :channel : nil
        # Both flares go on the right hand's item, and the flags can only
        # be set by WeaponBlessCheck, whose precondition refuses an empty
        # hand. Without this gate a profile that lists 902 or 411 while
        # holding nothing keeps Maintain (40) wanting control forever and
        # Engage (50) never runs. bigshot reads GameObj.right_hand.id
        # unguarded (check_902_411 9112) but self-paces on roundtime.
        when :bless_902, :bless_411
          next_bless_due(world, sign, state)
        else spell_due(world, sign.num, policy, now: now, renewal_cost: renewal_cost)
        end
      end

      # cast_signs 9127 hands "650 <aspect> <aspect|evoke>" to cmd_assume
      # every pass; its own early returns are the gate here: 650 known and
      # affordable, neither aspect up, not both on cooldown.
      #
      # @bigshot cast_signs, cmd_assume
      # @param world [World]
      # @param sign [Sign] the 650 entry, its args the two aspects
      # @return [Boolean]
      def assume_due?(world, sign)
        me = world.me
        s = world.spell[650]
        return false unless s && s.known? && s.affordable?

        # Assume's own gate: a word that is not an aspect refuses with
        # :bad_aspect every tick, so a profile typo would otherwise have
        # Maintain claim the tick forever. bigshot messages and moves on
        # (cmd_assume 5609).
        return false unless sign.args[0].to_s =~ Engage::Routines::ASPECTS

        aspect, extra = sign.args.map { |a| a.to_s.capitalize }
        return false if me.effect_active?("Aspect of the #{aspect}") || me.effect_active?("Aspect of the #{extra}")
        return false if me.spell_active?("Aspect of the #{aspect} Cooldown") && me.spell_active?("Aspect of the #{extra} Cooldown")

        # 'evoke' is a command word, not a second aspect, so there is no
        # "Aspect of the Evoke Cooldown" for the line above to find. bigshot
        # still has real work to do on the first pass - it evokes 650 and
        # prepares it (cmd_assume 5636-5640) - but once 650 is up and the
        # one real aspect is cooling, cmd_assume returns having sent
        # nothing. Left due, Maintain (40) re-took the tick from
        # Engage (50) on every one of those passes for the whole cooldown.
        if extra.to_s.casecmp('Evoke').zero? && me.spell_active?("Aspect of the #{aspect} Cooldown")
          return false if me.effect_active?('Assume Aspect') || me.effect_active?('650')
        end

        true
      end

      # Rapid Fire is due when known and affordable, not up with
      # time left, and not in recovery unless the entry carries an
      # argument.
      #
      # @param world [World]
      # @param sign [Sign] the 515 entry
      # @return [Boolean]
      def rapid_due?(world, sign)
        me = world.me
        s = world.spell[515]
        return false unless s && s.known? && s.affordable?
        return false if me.effect_active?('Rapid Fire') && me.buff_time_left('Rapid Fire') > 0.05
        return false if me.cooldown_active?('Rapid Fire Recovery') && sign.args.first.to_s.empty?

        true
      end

      # Whether a spell is known and affordable right now.
      #
      # @param world [World]
      # @param num [Integer] the spell number
      # @return [Boolean, nil] nil when the spell is unknown to Lich
      def spell_ready?(world, num)
        s = world.spell[num]
        s && s.known? && s.affordable?
      end

      # A 902/411 flare is due when its flag is clear, the spell is ready,
      # and there is something in the right hand to put it on.
      #
      # @param world [World]
      # @param sign [Sign] the 902 or 411 entry
      # @param state [State] the two flare flags
      # @return [Symbol, nil, false] :cast when due
      def next_bless_due(world, sign, state)
        flagged = sign.kind == :bless_902 ? state.blessed_902 : state.blessed_411
        return nil if flagged
        return nil if world.hands.right.id.nil?

        spell_ready?(world, sign.num) && :cast
      end

      # A cman sign is due only when the Maneuver action would take it:
      # bigshot gates 9605 and 9625 on CMan.known? and Overexerted before
      # it ever waits roundtime, then on stamina. Asking the
      # reader here keeps due no looser than the action it dispatches to,
      # so an untrained or overexerted technique is not claimed every tick.
      #
      # @bigshot cast_signs
      # @param me [World::Me]
      # @param name [String] the technique as CMan knows it
      # @return [Symbol, nil] :maneuver when due, else nil
      def cman_due?(me, name)
        return nil unless psm_known?(:cman, name)
        return nil if me.debuff_active?('Overexerted')
        return nil if me.cooldown_active?(name) || me.stamina < 30

        :maneuver
      end

      # The PSM readers, through the Maneuver action's own lookup so the
      # two cannot drift; nil outside Lich, which reads as not due.
      def psm_known?(category, name)
        r = Actions::Maneuver.reader_for(category)
        r ? r.known?(name) : false
      rescue StandardError
        false
      end

      def psm_available?(category, name)
        r = Actions::Maneuver.reader_for(category)
        r ? r.available?(name) : false
      rescue StandardError
        false
      end

      # The plain spell gate of cast_signs: known, not 9918, no Voln
      # symbol under 9012, the 597 mana penalty, the cooldown skips,
      # 1035 under Song of Tonis, short buffs on cooldown, not already
      # active, favor for the checked symbols, then affordability (a
      # :wrack when not and wracking is on), the song renewal reserve
      # and the 1.5 s recast gap.
      #
      # @bigshot cast_signs, 597 penalty, cost of 1
      # @param world [World]
      # @param num [Integer] the spell number
      # @param policy [Policy] the maintain settings
      # @param now [Time] the clock, for the recast gap
      # @param renewal_cost [Integer] a Bard's song renewal cost, 0 otherwise
      # @return [Symbol, nil] :cast, :wrack or nil
      def spell_due(world, num, policy, now:, renewal_cost:)
        me = world.me
        s = world.spell[num]
        return nil if s.nil? || !s.known?
        return nil if num == 9918
        return nil if VOLN_SYMBOLS.include?(num) && me.spell_active?(9012)

        cost = s.mana_cost.to_i
        # a five mana penalty while 597 is up
        return nil if me.spell_active?(597) && cost.positive? && cost + 5 > me.mana
        return nil if COOLDOWN_SKIPS[num] && me.cooldown_active?(COOLDOWN_SKIPS[num])
        return nil if num == 1035 && me.effect_active?('Song of Tonis')
        return nil if SHORT_BUFFS.include?(num) && me.cooldown_active?(s.name)
        return nil if s.active?

        return nil if FAVOR_CHECKED.include?(num) && policy.check_favor && !me.voln_symbol_affordable?(num)

        real_cost = cost > 1 ? cost : 0 # many erroneously return 1 (7479)
        # A wrack no society can pay is not due: Wrack would skip itself,
        # and Maintain would go on claiming the tick from Engage every
        # 0.25 s for as long as the sign stayed unaffordable. bigshot's
        # wrack() does nothing and cast_signs moves to the next sign.
        return :wrack if !s.affordable? && real_cost > me.mana && policy.use_wracking &&
                         Actions::Wrack.possible?(world, policy)
        return nil unless s.affordable?
        return nil if renewal_cost.positive? && me.mana < renewal_cost + cost
        return nil unless now > s.last_cast + 1.5

        :cast
      end
    end

    # mstrike_spell_check: a Paladin or Empath tops stamina up before
    # an mstrike that its floor would refuse. Rejuvenation when its
    # estimated gain reaches the floor; Adrenal Surge once every 301
    # seconds when popped muscles are up or the estimated gain reaches it.
    #
    # @bigshot mstrike_spell_check
    module Stamina
      # Blessings rank thresholds; each one reached adds 3 to Rejuvenation's gain.
      BLESSING_STEPS = [1, 3, 6, 10, 15, 21, 28, 36, 45, 55, 66, 78, 91, 105, 120, 136, 153, 171, 190].freeze
      # Seconds between Adrenal Surge casts.
      ADRENAL_INTERVAL = 301

      module_function

      # @param world [World]
      # @param floor [Integer] the stamina the mstrike needs
      # @param state [State] holds adrenal_at
      # @param now [Time] the clock, against adrenal_at
      # @return [Integer, nil] the spell to cast first, or nil
      def top_up_spell(world, floor:, state:, now: Time.now)
        me = world.me
        return nil unless me.profession.to_s =~ /Paladin|Empath/i

        floor = floor.to_i
        ranks = me.blessings_ranks
        rejuv = world.spell[1607]
        if rejuv && rejuv.known? && !rejuv.active? && rejuv.affordable? && me.stamina < floor
          bonus = BLESSING_STEPS.count { |n| ranks >= n }
          return 1607 if me.stamina + 15 + (bonus * 3) >= floor
        end

        adrenal = world.spell[1107]
        ready = state.adrenal_at.nil? || now >= state.adrenal_at + ADRENAL_INTERVAL
        return nil unless adrenal && adrenal.known? && adrenal.affordable? && !me.spell_active?(9010) && ready

        popped = me.spell_active?(9699)
        gain = if ranks >= 65 then me.max_stamina
               elsif ranks >= 35 then me.stamina + 50
               else me.stamina + 25
               end
        popped || gain >= floor ? 1107 : nil
      end
    end
  end

  module Actions
    # wrack: Sign of Wracking when the spirit floor allows, else
    # Sigil of Power per fifty stamina, else Symbol of Mana off cooldown.
    # Each society reader (Lich::Gemstone::Societies::CouncilOfLight,
    # GuardiansOfSunfist, OrderOfVoln) answers known?, affordable?,
    # available? and command (lich-5 #1589); their +use+ sends bare and
    # reads nothing, so the engine sends the reader's command itself and
    # confirms on mana rising.
    #
    # @bigshot wrack
    class Wrack < Base
      include CombatRt

      # Sigils of Power sent in one wrack, at most.
      MAX_SIGILS = 4

      # @param world [World]
      # @param policy [Maintain::Policy] for wracking_spirit
      # @param timeout [Numeric] seconds to wait for mana to rise per send
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, policy:, timeout: 3, **opts)
        super(world, **opts)
        @policy = policy
        @timeout = timeout
      end

      # @return [Symbol] :ok, :dead or :muckled
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # Whether any wrack source can pay right now. Signs.due asks this
      # before returning :wrack so Maintain does not claim the tick for a
      # wrack that would refuse itself; perform asks the same questions in
      # the same order. bigshot's wrack() simply falls through its if/elsif
      # chain and cast_signs carries on.
      #
      # @bigshot wrack
      # @param world [World]
      # @param policy [Maintain::Policy]
      # @return [Boolean]
      def self.possible?(world, policy)
        new(world, policy: policy).possible?
      end

      # @return [Boolean]
      def possible?
        return true if wracking_ready?
        return true if sunfist&.available?('power')

        (voln&.available?('mana') && !me.cooldown_active?('Symbol of Mana')) ? true : false
      end

      # Wracking, else up to MAX_SIGILS Sigils of Power while available,
      # else Symbol of Mana; :no_wrack when none applies.
      #
      # @return [Actions::Result] :wracking, :sigil_of_power or :symbol_of_mana on success
      def perform
        if wracking_ready?
          confirm(command_for(col, 'wracking'), :wracking)
        elsif sunfist&.available?('power')
          last = nil
          MAX_SIGILS.times do
            break unless sunfist.available?('power')

            last = confirm(command_for(sunfist, 'power'), :sigil_of_power)
            break unless last.success?
          end
          last
        elsif voln&.available?('mana') && !me.cooldown_active?('Symbol of Mana')
          confirm(command_for(voln, 'mana'), :symbol_of_mana)
        else
          # No society wrack applies right now. Nothing is sent, and
          # Signs.spell_due will ask again next tick, so a :failed here
          # was five failures in five ticks and a stopped hunt with
          # nothing on the wire.
          Result.new(status: :skipped, reason: :no_wrack)
        end
      end

      private

      # bigshot: three floors, all of them. wracking_spirit is the
      # profile's own, 9012 the lockout, and 6 + owed the reserve that
      # keeps the dissipating signs from taking spirit to zero when they
      # expire. The reader's own affordable? does not supply that last
      # one: Lich adds pending_spirit_loss only for a sign whose
      # cost_type is :dissipates, and Sign of Wracking is :invoked
      # (council_of_light.rb 205, 369). bigshot reaches the same floor
      # through Spell#cast (spell.rb 610); the engine sends the reader's
      # command itself, so it has to check for itself.
      def wracking_ready?
        col&.available?('wracking') && !me.spell_active?(9012) &&
          me.spirit >= @policy.wracking_spirit.to_i && me.spirit >= 6 + owed_spirit
      end

      # The spirit the active dissipating signs still owe, counted
      # bigshot's way: one each for Swords, Shields and Dissipation,
      # three for Sign of Possession.
      #
      # @bigshot wrack
      def owed_spirit
        [9912, 9913, 9914].count { |num| me.spell_active?(num) } + (me.spell_active?(9916) ? 3 : 0)
      end

      def command_for(reader, name) = reader.command(name)

      def confirm(command, reason)
        before = me.mana
        result = send_and_observe(command, timeout: @timeout) { me.mana > before }
        result.success? ? Result.new(status: :success, reason: reason) : result
      end

      # The seams: nil outside Lich or when the society module is absent.
      def col = society('CouncilOfLight')
      def sunfist = society('GuardiansOfSunfist')
      def voln = society('OrderOfVoln')

      # The readers live under Lich::Gemstone::Societies. Society (the
      # base class) has no such constants, and the NameError that lookup
      # raised was rescued as "no society", so no wrack ever sent.
      def society(name)
        ::Lich::Gemstone::Societies.const_get(name)
      rescue NameError
        nil
      end
    end

    # check_902_411: a quiet LOOK at the right hand tells whether
    # 902 ("gleams faintly with inner light") and 411 ("surrounded by a
    # scintillating") are already on it.
    #
    # @bigshot check_902_411
    class WeaponBlessCheck < Base
      # The LOOK line that says 902 is on the item.
      GLEAMS = /gleams faintly with inner light/
      # The LOOK line that says 411 is on the item.
      SCINTILLATING = /is surrounded by a scintillating/
      # The line that says 902 has left the item (hunt_monitor 2846).
      STOPS_GLOWING = %r{Your <a exist="(?<id>[^"]+)"[^>]*>.*?</a> stops glowing\.}i
      # The line that says 411 has left it (hunt_monitor 2848).
      FADES_AWAY = %r{The scintillating.*?light surrounding the <a exist="(?<id>[^"]+)"[^>]*>.*?</a> fades away\.}i

      # @param world [World]
      # @param state [Maintain::State] where the two flags are written
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, state:, **opts)
        super(world, **opts)
        @state = state
      end

      # @return [Symbol] :ok, :dead or :empty_hand
      def preconditions
        return :dead if me.dead?
        return :empty_hand if @world.hands.right.id.nil?

        :ok
      end

      # LOOK at the right hand's item and set the state's two flags.
      #
      # @return [Actions::Result] success, the LOOK lines joined as the line
      def perform
        lines = look_at(@world.hands.right.id).join(' ')
        @state.blessed_902 = lines.match?(GLEAMS)
        @state.blessed_411 = lines.match?(SCINTILLATING)
        Result.new(status: :success, line: lines)
      end

      private

      def look_at(id)
        ::Lich::Util.quiet_command_xml("look at ##{id}", /You see nothing unusual\.|I could not find|The <a exist="(.*?)" noun=".*?">.*?<\/a>/)
      end
    end

    # cmd_bless for one item: 1604 at it, else 304 at it, else
    # SYMBOL BLESS, else there is no blessing and the hunt must stop.
    #
    # @bigshot cmd_bless
    class Bless < Base
      include CombatRt

      # 1604's success line.
      ENFOLDS = /A violet tongue of flame enfolds the/

      # @param world [World]
      # @param item_id [String, Integer] the item to bless, by id
      # @param opts [Hash] passed to Base (interrupt)
      def initialize(world, item_id:, **opts)
        super(world, **opts)
        @item_id = item_id.to_s
      end

      # @return [Symbol] :ok, :dead or :muckled
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # 1604 confirmed by ENFOLDS, else 304 sent unread, else SYMBOL BLESS
      # through the ladder, else :no_blessing.
      #
      # @return [Actions::Result] :spell_1604, :spell_304 or :symbol_bless on success
      def perform
        spell = @world.spell
        if spell[1604]&.known? && spell[1604].affordable?
          answer = spell[1604].cast("##{@item_id}", ENFOLDS)
          return Result.new(status: :success, reason: :spell_1604, line: answer.to_s) if answer.to_s =~ ENFOLDS
        end
        if spell[304]&.known? && spell[304].affordable?
          spell[304].cast("##{@item_id}")
          Result.new(status: :success, reason: :spell_304)
        elsif spell[9802]&.known?
          first = send_through_ladder("symbol bless ##{@item_id}")
          first.is_a?(Result) ? first : Result.new(status: :success, reason: :symbol_bless, line: first)
        else
          Result.new(status: :failed, reason: :no_blessing)
        end
      end
    end
  end

  module Behaviors
    # One bless or one sign per tick.
    class Maintain < Behavior
      # @!attribute [r] state
      #   @return [Maintain::State] the bless flags and wanted list
      # @!attribute [r] signs
      #   @return [Array<Maintain::Sign>] the profile's signs, parsed once
      attr_reader :state, :signs

      # @param policy [Maintain::Policy]
      # @param state [Maintain::State] shared with the script
      # @param renewal_cost [#call] -> Integer, a Bard's song renewal cost
      # @param clock [#now] the time source
      # @param buffs [BuffPolicy::Coordinator, nil] opt-in requirements shared with Rest
      # @param signs_wanted [#call] -> Boolean, false while signs are held for the walk
      def initialize(policy:, state: EO::Engine::Maintain::State.new, renewal_cost: nil, clock: Time, buffs: nil,
                     signs_wanted: -> { true })
        super()
        @policy = policy
        @state = state
        @signs = EO::Engine::Maintain::Signs.parse(policy.signs)
        @renewal_cost = renewal_cost || -> { 0 }
        @clock = clock
        @buffs = buffs
        @signs_wanted = signs_wanted
        @due = nil
        install_watch
      end

      # @return [Integer] 40
      def priority = 40

      # Whether a bless is wanted or a sign is due, remembered for tick.
      #
      # Signs belong at the hunting room, where bigshot's pre_hunt casts
      # them and where Rest issues its cast_signs order. Held everywhere
      # else in the cycle: parked in the refuge, walking home, walking
      # back out. A sign cast on the way out burns for the whole trip and
      # can dissipate before the first fight.
      #
      # Anything wanted earlier belongs in the hunting prep commands,
      # which reach the game verbatim. Rest's own buff recovery still
      # runs at the refuge through restore_buff, which is called directly
      # and does not pass through this gate.
      #
      # @param world [World]
      # @return [Boolean]
      def wants_control?(world)
        @due = nil
        return false unless @signs_wanted.call

        return true if @buffs && @buffs.assess(world).any? { |need| %w[recast pending spellup spellup_check].include?(need.state) }

        @due = next_due(world)
        !@due.nil?
      end

      # The one due thing: a bless, a wrack, Seanette's Shout, a stamina
      # maneuver, 909's channel, a cast, or an Assume.
      #
      # @param world [World]
      # @return [Actions::Result, nil] nil when nothing is due
      def tick(world)
        return nil unless @signs_wanted.call

        if @buffs && @buffs.assess(world).any? { |need| %w[recast pending spellup spellup_check].include?(need.state) }
          return restore_buff(world)
        end
        due = @due || next_due(world)
        return nil if due.nil?

        kind, subject = due
        case kind
        when :bless then bless(world, subject)
        when :wrack then Actions::Wrack.new(world, policy: @policy).call
        when :shout then Actions::Maneuver.new(world, category: :warcry, name: "Seanette's Shout").call
        when :maneuver then Actions::Maneuver.new(world, category: :cman, name: subject.kind == :surge ? 'Surge of Strength' : 'Burst of Swiftness').call
        when :channel
          world.spell[909].force_channel
          Actions::Result.new(status: :success, reason: :channel_909)
        when :cast then cast_sign(world, subject)
        when :assume then Actions::Assume.new(world, aspect: subject.args[0].to_s, extra: subject.args[1].to_s).call
        end
      end

      # One native restoration using the same sign/cooldown gates and Cast
      # action as legacy maintenance. Rest may call this while at refuge.
      # @param world [World]
      # @return [Actions::Result, nil] pending observations do not send commands
      def restore_buff(world)
        needs = @buffs&.assess(world) || []
        return nil if needs.any? { |entry| entry.state == 'pending' }
        return nil if world.me.in_rt? || world.me.in_cast_rt?

        if needs.any? { |entry| entry.state == 'spellup_check' }
          result = Actions::ManaSpellupStatus.new(world).call
          @buffs.spellup_checked!(result.success? && result.reason == :available)
          return result
        end

        bulk = needs.select { |entry| entry.state == 'spellup' }
        unless bulk.empty?
          @buffs.spellup_attempted!(bulk.map { |entry| entry.rule.spell })
          return Actions::Command.new(world, command: 'mana spellup').call
        end
        need = needs.find { |entry| entry.state == 'recast' }
        return nil unless need

        sign = EO::Engine::Maintain::Signs.parse([need.rule.spell.to_s]).first
        why = EO::Engine::Maintain::Signs.due(world, sign, @policy, @state, now: @clock.now,
                                                                            renewal_cost: @renewal_cost.call.to_i)
        # Only an attempt that is about to be made counts as one. Counting
        # first meant a cooldown, an unaffordable cast or anything else that
        # makes `due` answer something other than :cast spent a recovery
        # attempt without sending a thing - two checks inside one cooldown
        # exhausted the budget and forced a field or town recovery that was
        # never needed.
        return nil unless why == :cast && sign.kind == :spell

        # CAST does not recognize a literal "self" target. Use the native
        # player name, also avoiding INCANT's configured/current target.
        target = world.me.name.to_s
        return nil if target.empty?

        @buffs.attempted!(need.rule.spell)
        Actions::Cast.new(world, spell: sign.num, target: target).call
      end

      private

      def next_due(world)
        return [:bless, @state.bless_wanted.last] if @policy.bless && @state.bless_wanted.any?

        @signs.each do |sign|
          next if @buffs&.manages?(sign.num)
          why = EO::Engine::Maintain::Signs.due(world, sign, @policy, @state, now: @clock.now, renewal_cost: @renewal_cost.call.to_i)
          return [why, sign] if why
        end
        nil
      end

      def bless(world, item_id)
        result = Actions::Bless.new(world, item_id: item_id).call
        if result.success?
          @state.bless_wanted.delete(item_id)
        elsif result.reason == :no_blessing
          @state.bless_wanted.clear
          Events.emit(:maintain_stuck, reason: 'No blessing on weapon')
        end
        result
      end

      def cast_sign(world, sign)
        item = sign.kind == :bless_411 ? world.hands.right : nil
        result = Actions::Cast.new(world, spell: sign.num, item: item).call
        Actions::WeaponBlessCheck.new(world, state: @state).call if %i[bless_902 bless_411].include?(sign.kind)
        result
      end

      # hunt_monitor 2359-2367: a blessed item that "strikes true" but is
      # shrugged off, when it is our ammo, in our inventory or in hand,
      # wants a bless; so does one whose blessing "returns to normal".
      def install_watch
        ammo = @policy.ammo.to_s
        state = @state
        Events.on(:bless_shrugged) do |e|
          next unless ammo == e.data[:noun] || e.data[:mine]

          state.bless_wanted << e.data[:id] unless state.bless_wanted.include?(e.data[:id])
        end
        Events.on(:bless_expired) { |e| state.bless_wanted << e.data[:id] unless state.bless_wanted.include?(e.data[:id]) }

        # 902 and 411 are LOOKed for once and then remembered, so nothing
        # recast them when the game said they had lapsed. bigshot watches
        # both lines in hunt_monitor and re-LOOKs at each hunt
        # start. Two rules of our own, the way Flee registers the
        # profile's flee_message (flee.rb 407).
        Watch.on(Actions::WeaponBlessCheck::STOPS_GLOWING, :weapon_flare_faded) { |m| { id: m[:id], num: 902 } }
        Watch.on(Actions::WeaponBlessCheck::FADES_AWAY, :weapon_flare_faded) { |m| { id: m[:id], num: 411 } }
        Events.on(:weapon_flare_faded) do |e|
          case e.data[:num]
          when 902 then state.blessed_902 = false
          when 411 then state.blessed_411 = false
          end
        end
      end
    end
  end
end
