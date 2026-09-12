# frozen_string_literal: true

# ============================================================================
# routines (the rest of bigshot's cmd_* vocabulary)
# ============================================================================

#
# Engage dispatches the common routine words (spells, maneuvers, the
# attack verbs, mstrike, hide, script, sleep, stance, wait, ambush, weed).
# This part carries the rest of bigshot 5.16's cmd_* table, read from the
# local bigshot (the Creature-migrated 5.16.0): the sorcerer and caster
# routines, the unarmed machine, wands, ranged aiming and dislodge, the
# force / eachtarget / celerity / slayer / tonis prefixes, weapon reaction,
# and the hunt_monitor lines that feed them. Each is an Action with
# bigshot's commands and gates, bounded where bigshot loops. Line
# references are to C:\Gemstone\dev\lich-5\scripts\bigshot.lic 5.16.0.
#
module EO::Engine
  # The fight loop's namespace; this part adds the routine words to it.
  module Engage
    # bigshot's globals for these routines ($bigshot_*), per fight.
    class State
      # The routine-owned fight state, one accessor per bigshot global:
      # the offered weapon reaction, the hurled weapon's bond return, the
      # archery aim index and last location, the dislodge target, the UCS
      # follow-up flag and attack word, the UAC aim index, the wand list
      # cursor, the last resonance bolt, and the dhurl part cursor.
      #
      # @return [Object, nil]
      attr_accessor :reaction, :bond_returned, :archery_aim, :archery_location, :dislodge_target,
                    :unarmed_followup, :unarmed_followup_attack, :uac_aim, :wand_index, :resonance_last, :dhurl_cursor
      # Lists the routines fill in place: locations an arrow is stuck in,
      # locations to dislodge, and the ids already smote.
      #
      # @return [Array, nil]
      attr_reader :archery_stuck, :dislodge_locations, :smite_done

      # Back to bigshot's starting values. The smite list clears only on a
      # room change (or when never set); the wand cursor is kept across fights.
      #
      # @param moved [Boolean] true when we changed rooms since the last reset
      # @return [void]
      def routines_reset!(moved: true)
        @reaction = nil
        @archery_aim = 0
        @archery_stuck = []
        @archery_location = nil
        @dislodge_locations = []
        @dislodge_target = nil
        @unarmed_followup = false
        @unarmed_followup_attack = ''
        @uac_aim = 0
        @dhurl_cursor = 0
        @smite_done = [] if moved || @smite_done.nil?
        @wand_index ||= 0
        @bond_returned = false
      end

      # The smote-id list, created on first use.
      #
      # @return [Array<String>] target ids Smite has finished with
      def smite_done? = (@smite_done ||= [])
    end

    # The rest of bigshot's cmd_* vocabulary: `run` matches a routine word
    # and hands it to its Action; see the file header.
    module Routines
      # The buff-then-command prefixes (cmd 3359-3387): celerity/haste/506,
      # slayer/240, tonis/1035, each followed by the command.
      #
      # The numeric forms are spell numbers too, so "506 evoke" reads both
      # ways: a prefix whose command is "evoke", or spell 506 cast in the
      # evoke mode. The mode is what the writer meant - a prefix exists to
      # buff and then do something else, and a bare cast mode is not
      # something else. The lookahead leaves those to SPELL; every other
      # word ("506 attack", "240 cman bullrush") is a prefix as before.
      PREFIX = /^(celerity|haste|506|slayer|240|tonis|1035)\s+(?!(?:open|closed|cast|channel|evoke)\b)(.*)/i
      # The aspects ASSUME accepts; bigshot cmd_assume's list.
      ASPECTS = /^(?:jackal|wolf|lion|panther|hawk|owl|porcupine|rat|bear|burgee|mantis|serpent|spider|yierka)$/i

      module_function

      # Match the routine word and run its Action with the fight's target,
      # policy and state.
      #
      # @param engage [Behaviors::Engage] the fight: target, policy, state, dispatch
      # @param world [World]
      # @param text [String] the routine word and its arguments, lowercased
      # @param line [Object] the routine line being run, for `done_in_room?` and re-dispatch
      # @return [Actions::Result, nil] nil when the word is not ours
      def run(engage, world, text, line)
        target = engage.target
        policy = engage.policy
        state = engage.state
        state.routines_reset!(moved: false) if state.archery_stuck.nil?
        case text
        when /^prepare\b/i
          name = Preparations.name(text) if policy.preparations && !policy.preparations.empty?
          name ? Actions::Prepare.new(world, name: name, preparations: policy.preparations).call : Actions::Command.new(world, command: text).call
        when /^sacrifice\b/ then Actions::Sacrifice.new(world, target: target).call
        when /^tether( recast)?\b/ then Actions::Tether.new(world, target: target, recast_on_transfer: !Regexp.last_match(1).nil?, targets_policy: engage.targets_policy).call
        when /^efury\s?(fire|cold)?/ then Actions::Efury.new(world, target: target, extra: Regexp.last_match(1)).call
        when /^phase\b/ then Actions::Phase.new(world, target: target).call
        when /^curse\s+(clumsy|weakness|darkness|itch|hex|pox|nightmare|star)$/ then Actions::Curse.new(world, target: target, kind: Regexp.last_match(1)).call
        when /^dhurl\s?(.*)?/ then dhurl(engage, world, Regexp.last_match(1))
        when /^caststop\s+(\d+)\s?(.*)?/ then Actions::CastStop.new(world, target: target, spell: Regexp.last_match(1).to_i, extra: Regexp.last_match(2)).call
        when /^depress\b/ then Actions::Depress.new(world, target: target, already: state.done_in_room?(line.raw)).call
        when /^(?:unravel|barddispel)\s?(.*)?/ then Actions::Unravel.new(world, target: target, extra: Regexp.last_match(1)).call
        when /^resonance\s+([\d\s]+)/ then resonance(engage, world, Regexp.last_match(1))
        when /^stomp\b/ then Actions::Stomp.new(world).call
        when /^leech\b/ then Actions::Leech.new(world).call
        when /^rapid(?:fire)?\s?(ignore)?/ then rapid(world, Regexp.last_match(1))
        when /^jewel (\w+)/ then Actions::Jewel.new(world, mnemonic: Regexp.last_match(1)).call
        when /^briar\s?(\w+)/ then Actions::Briar.new(world, weapon: Regexp.last_match(1)).call
        when /^assume\s?(\w+)?\s?(\w+)?/ then Actions::Assume.new(world, aspect: Regexp.last_match(1).to_s, extra: Regexp.last_match(2).to_s).call
        when /^throw\b/ then Actions::Throw.new(world, target: target).call
        when /^wield\s+(\w+)\s?(left|right)?/ then Actions::Wield.new(world, noun: Regexp.last_match(1), hand: Regexp.last_match(2).to_s).call
        when /^store\s*(left|right|both)?/ then Actions::Store.new(world, hand: Regexp.last_match(1) || 'both').call
        when /^nudgeweapons?\b/ then Actions::NudgeWeapons.new(world, stance: engage.stance, wander_stance: policy.wander_stance).call
        when /^berserk\b/ then Actions::Berserk.new(world, stance: engage.stance, wander_stance: policy.wander_stance).call
        when /^smite\b/ then Actions::Smite.new(world, target: target, state: state).call
        when /^unarmed\s+([a-z]*).?([a-z]*)?$/ then Actions::Unarmed.new(world, engage: engage, command: Regexp.last_match(1), manual_aim: Regexp.last_match(2).to_s).call
        when /^wandolier((?:\s+\w+){0,2})/ then Actions::Wandolier.new(world, target: target, policy: policy, state: state, args: Regexp.last_match(1), stance: engage.stance).call
        when /^wand\b/ then Actions::Wand.new(world, target: target, policy: policy, state: state, stance: engage.stance).call
        when /^fire\b/ then Actions::Ranged.new(world, target: target, policy: policy, state: state).call
        # Anchored like every other word here. Unanchored, this was tested
        # before force, eachtarget and PREFIX and matched inside them, so
        # `force dislodge head till 3` ran a bare dislodge with 'till 3'
        # folded into its location list and the wrapper silently dropped.
        when /^dislodge\s?(.*)/ then Actions::Dislodge.new(world, target: target, state: state, locations: Regexp.last_match(1)).call
        when /^force\s+(.*)\s+(?:till|until)\s+(\d+)/i then force(engage, world, Regexp.last_match(1), Regexp.last_match(2).to_i, line)
        when /^eachtarget\s+(.*)/i then each_target(engage, world, Regexp.last_match(1), line)
        when PREFIX then prefixed(engage, world, Regexp.last_match(1), Regexp.last_match(2), line)
        end
      end

      # cmd 3359-3387: celerity / slayer / tonis before the command. The
      # buff is cast only when it is not up (or about to drop); slayer and
      # tonis also want it known, affordable, and slayer off cooldown.
      #
      # @bigshot cmd
      # @param engage [Behaviors::Engage]
      # @param world [World]
      # @param word [String] the prefix matched by PREFIX
      # @param rest [String] the command after it
      # @param line [Object] the routine line, re-dispatched with `rest`
      # @return [Actions::Result, nil] whatever the dispatched command returns
      def prefixed(engage, world, word, rest, line)
        spell = world.spell
        case word.downcase
        when 'celerity', 'haste', '506'
          s = spell[506]
          engage.spell(world, nil, 506, '') if s && (!s.active? || s.timeleft.to_f <= 0.05)
        when 'slayer', '240'
          s = spell[240]
          s.cast if s && s.known? && s.affordable? && !world.me.cooldown_active?(s.name) && (!s.active? || s.timeleft.to_f <= 0.05)
        when 'tonis', '1035'
          s = spell[1035]
          s.cast if s && s.known? && s.affordable? && (!s.active? || s.timeleft.to_f <= 0.05)
        end
        engage.dispatch(world, rest.strip.downcase, line)
      end

      # cmd_resonance_bolt: a random bolt from the list, never the
      # same one twice running.
      #
      # @bigshot cmd_resonance_bolt
      # @param engage [Behaviors::Engage]
      # @param world [World]
      # @param ids [String] the spell numbers, space-separated
      # @return [Actions::Result] the incant, or :no_bolt with nothing left to pick
      def resonance(engage, world, ids)
        options = ids.split.map(&:to_i).uniq - [engage.state.resonance_last]
        pick = options.sample
        return Actions::Result.new(status: :failed, reason: :no_bolt) if pick.nil?

        engage.state.resonance_last = pick
        engage.spell(world, 'incant', pick, '')
      end

      # cmd_rapid: cast 515 when known, affordable, not already up,
      # and off its recovery cooldown unless told to ignore it.
      #
      # @bigshot cmd_rapid
      # @param world [World]
      # @param ignore [String, nil] "ignore" to cast through Rapid Fire Recovery
      # @return [Actions::Result] the cast, or the gate that refused
      def rapid(world, ignore)
        s = world.spell[515]
        me = world.me
        return Actions::Result.new(status: :failed, reason: :unknown_spell) unless s&.known?
        return Actions::Result.new(status: :failed, reason: :unaffordable) unless s.affordable?
        return Actions::Result.new(status: :failed, reason: :active) if me.effect_active?('Rapid Fire') && me.buff_time_left('Rapid Fire') > 0.05
        return Actions::Result.new(status: :failed, reason: :cooldown) if me.cooldown_active?('Rapid Fire Recovery') && ignore.to_s.empty?

        Actions::Cast.new(world, spell: 515).call
      end

      # cmd_dhurl: HURL at the next part in the profile's ambush
      # list, then recover the weapon. A refused part advances the cursor
      # for the next call; anything else resets it.
      #
      # @bigshot cmd_dhurl
      # @param engage [Behaviors::Engage]
      # @param world [World]
      # @param part [String, nil] one part to hurl at, or nil for the ambush list
      # @return [Actions::Result] the Dhurl action's Result
      def dhurl(engage, world, part)
        state = engage.state
        parts = part.to_s.empty? ? Array(engage.policy.ambush) : [part]
        parts = ['chest'] if parts.empty?
        state.dhurl_cursor = 0 if state.dhurl_cursor.to_i >= parts.size
        result = engage.with_hurl_equipment(world) do |weapon_ids, interrupt|
          Actions::Dhurl.new(world, target: engage.target, part: parts[state.dhurl_cursor.to_i], state: state,
                            expected_ids: weapon_ids, interrupt: interrupt).call
        end
        state.dhurl_cursor = result.reason == :part_refused ? state.dhurl_cursor.to_i + 1 : 0
        result
      end

      # cmd_force: repeat the command until its endroll reaches the
      # goal, thirty seconds at most, stopping on a failure line or a
      # muckle. The endroll arrives as a :force_roll event: Lich's combat
      # observers parse the roll line and the watch relays it.
      #
      # @bigshot cmd_force
      # @param engage [Behaviors::Engage]
      # @param world [World]
      # @param command [String] the routine command to repeat
      # @param goal [Integer] the endroll to reach
      # @param line [Object] the routine line, re-dispatched with `command`
      # @return [Actions::Result, nil] :goal_met, or :force_failed / :out_of_mana /
      #   :target_gone / :force_timeout; the command's own Result when it fails
      #   for any reason but :condition; nil when the command is not a routine
      def force(engage, world, command, goal, line)
        rolls = []
        watching = Events.on(:force_roll) { |e| rolls << e.data[:roll] }
        deadline = Time.now + 30
        result = nil
        begin
          loop do
            rolls.clear
            result = engage.dispatch(world, command.strip.downcase, line)
            return result if result.nil? || (result.failed? && result.reason != :condition)

            sleep 0.1
            return Actions::Result.new(status: :failed, reason: :force_failed) if world.me.muckled?
            return Actions::Result.new(status: :success, reason: :goal_met) if rolls.any? { |r| r >= goal }
            return Actions::Result.new(status: :failed, reason: :out_of_mana) if command =~ /^(\d+) / && !world.spell[Regexp.last_match(1).to_i]&.affordable?
            return Actions::Result.new(status: :failed, reason: :target_gone) unless Array(world.room.targets).any? { |t| t.id.to_s == engage.target&.id.to_s }
            return Actions::Result.new(status: :failed, reason: :force_timeout) if Time.now > deadline
          end
        ensure
          Events.off(watching)
        end
      end

      # cmd_eachtarget: the command once at every valid creature,
      # then the game's target back on ours.
      #
      # @bigshot cmd_eachtarget
      # @param engage [Behaviors::Engage]
      # @param world [World]
      # @param command [String] the routine command to run at each creature
      # @param line [Object] the routine line, re-dispatched with `command`
      # @return [Actions::Result] the last creature's Result, or :no_target with none
      def each_target(engage, world, command, line)
        current = engage.target
        last = nil
        Targets.candidates(world.room.targets, engage.targets_policy).each do |creature|
          Actions::Target.new(world, target: creature).call unless world.me.current_target_id.to_s == creature.id.to_s
          engage.retarget(creature)
          last = engage.dispatch(world, command.strip.downcase, line)
        end
        engage.retarget(current)
        Actions::Target.new(world, target: current).call if current && world.me.current_target_id.to_s != current.id.to_s
        last || Actions::Result.new(status: :failed, reason: :no_target)
      end
    end
  end

  module Actions
    # cmd_sacrifice: two spirit, off cooldown, APPRAISE for
    # "enticingly frail", then SACRIFICE.
    #
    # @bigshot cmd_sacrifice
    class Sacrifice < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      # @return [Symbol] :ok, or :dead, :low_spirit, :cooldown
      def preconditions
        return :dead if me.dead?
        return :low_spirit if me.spirit < 2
        return :cooldown if me.cooldown_active?('Sacrifice')

        :ok
      end

      # @return [Actions::Result] :not_frail when the appraisal does not say so,
      #   else the SACRIFICE's first answer line
      def perform
        lines = appraise
        return Result.new(status: :failed, reason: :not_frail, line: lines.last) unless lines.any? { |l| l =~ /enticingly frail/ }

        send_and_match("sacrifice ##{@target.id}", /.*/, timeout: 3)
      end

      private

      def appraise
        ::Lich::Util.issue_command("appraise ##{@target.id}", /^The .+? is \w+ in size/, include_end: false, quiet: true, silent: true)
      rescue StandardError
        []
      end
    end

    # cmd_tether: incant 706 (five hindrance retries), then hold for
    # the completion or break line up to twelve seconds; with recast, when
    # the target dies and the chains transfer, chase the new target.
    #
    # @bigshot cmd_tether
    class Tether < Base
      include CombatRt

      # The chains finished with the target (bigshot's completion line).
      COMPLETE = /dissolve into black mist/
      # The chains broke or faded before finishing.
      BROKEN = /^You struggle to maintain control of the dark force, but you feel it break away!|^You feel your connection to the dark presence fade away\./
      # The target died and the chains moved to another creature.
      TRANSFER = /^As the signs of life fade from an? [\w\s\-]+, the tenebrous chains binding [\w\s\-]+ begin to vibrate and emit a sinister thrum that emanates through the surrounding area\.$/
      # How many transfers a recast will chase before giving up.
      MAX_CHASE = 3

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param recast_on_transfer [Boolean] chase the chains to the next target
      # @param targets_policy [Targets::Policy, nil] validates a chased target; default policy when nil
      # @param chase [Integer] how many transfers this cast has already followed
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, recast_on_transfer: false, targets_policy: nil, chase: 0, **opts)
        super(world, target: target, **opts)
        @target = target
        @recast = recast_on_transfer
        @targets_policy = targets_policy || Targets::Policy.new
        @chase = chase
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[706]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success with the reason: :complete, :running
      #   (the hold ended without a line), :ended, :no_transfer, :chase_limit,
      #   or the chased cast's own Result
      def perform
        s = @world.spell[706]
        answer = nil
        5.times do
          answer = s.force_incant(nil, COMPLETE)
          return Result.new(status: :success, reason: :complete, line: answer.to_s) if answer.to_s =~ COMPLETE
          break unless answer.to_s =~ /Spell Hindrance/i
        end
        state = :running
        transferred = false
        deadline = clock_now + 12
        until clock_now > deadline || interrupted?
          line = next_line
          if line.nil?
            break unless target_still_live?

            sleep 0.5
            next
          end
          if line =~ COMPLETE || line =~ BROKEN
            state = :complete
            break
          elsif line =~ TRANSFER
            transferred = true
            break
          end
        end
        return Result.new(status: :success, reason: state) if state == :complete || !@recast
        return Result.new(status: :success, reason: :ended) unless transferred || !target_still_live?

        sleep 0.5 if transferred
        new_id = me.current_target_id.to_s
        return Result.new(status: :success, reason: :no_transfer) if new_id.empty? || new_id == @target.id.to_s
        return Result.new(status: :success, reason: :chase_limit) if @chase >= MAX_CHASE

        creature = Array(@world.room.targets).find { |t| t.id.to_s == new_id }
        return Result.new(status: :success, reason: :no_transfer) if creature.nil? || !Targets.valid?(creature, @world.room.targets, @targets_policy)

        Tether.new(@world, target: creature, recast_on_transfer: true, targets_policy: @targets_policy, chase: @chase + 1, interrupt: @interrupt).call
      end
    end

    # cmd_efury: incant 917, then hold up to twelve seconds for the
    # ground to calm, standing if knocked down.
    #
    # @bigshot cmd_efury
    class Efury < Base
      include CombatRt

      # The ground calmed, the fire or cold variant resolved, or the target's
      # shield absorbed the spell: the hold is over.
      COMPLETE = /The (?:floor|ground) beneath .* suddenly calms\.|Heat rises from the ground near .* causing a brief swelter\.|An icy mist rises from the ground near .* as the ground rumbles\.|The evanescent shield shrouding .* flares to life and absorbs the essence of the spell, dissipating it harmlessly\./

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param extra [String, nil] "fire" or "cold", appended to the incant
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @extra = extra
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[917]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success: :complete on the calm line, :ended
      #   when the hold ran out or the target left
      def perform
        answer = @world.spell[917].force_incant(@extra.to_s)
        return Result.new(status: :success, reason: :complete) if answer.to_s =~ COMPLETE

        deadline = clock_now + 12
        until clock_now > deadline || interrupted? || !target_still_live?
          line = next_line
          return Result.new(status: :success, reason: :complete, line: line) if line && line =~ COMPLETE

          send_through_ladder('stand') unless me.standing?
          sleep 0.5 if line.nil?
        end
        Result.new(status: :success, reason: :ended)
      end
    end

    # cmd_phase: force_cast 704 at the target.
    #
    # @bigshot cmd_phase
    class Phase < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[704]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success, :phased; the cast's answer is not read
      def perform
        @world.spell[704].force_cast("##{@target.id}")
        Result.new(status: :success, reason: :phased)
      end
    end

    # cmd_curse: PREP 715 until ready, then CURSE #id <kind>.
    #
    # @bigshot cmd_curse
    class Curse < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param kind [String] the curse: clumsy, weakness, darkness, itch, hex, pox,
      #   nightmare or star
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, kind:, **opts)
        super(world, target: target, **opts)
        @target = target
        @kind = kind
      end

      # @return [Symbol] :ok, or :dead, :star_active, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?
        return :star_active if @kind == 'star' && me.spell_effect_time_left('Curse of the Star (bonus)') > 0.5

        s = @world.spell[715]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] the CURSE's first answer line; :prep_timeout,
      #   :interrupted or :unaffordable when the prep never readied
      def perform
        deadline = clock_now + 10
        until me.prepared_spell.to_s == 'Curse'
          return Result.new(status: :failed, reason: :prep_timeout) if clock_now > deadline
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          return Result.new(status: :failed, reason: :unaffordable) unless @world.spell[715].affordable?

          settle_rt
          send_through_ladder('release') unless me.prepared_spell.to_s == 'None'
          send_and_match('prep 715', /Your spell is ready\./, timeout: 2)
        end
        settle_rt
        send_and_match("curse ##{@target.id} #{@kind}", /.*/, timeout: 3)
      end
    end

    # cmd_dhurl one throw: HURL #id <part>; a refused part is the
    # caller's cue to move on; a throw waits out the flight and recovers.
    #
    # @bigshot cmd_dhurl
    class Dhurl < Base
      include CombatRt

      # The weapon left our hand.
      THROWN = /With a quick flick of your wrist, you deftly send .+ into flight\.|^You throw|^You take aim and throw/
      # Nothing worth hurling, or nothing to recover.
      NOTHING = /That's not going to do much\.  Try using a weapon|You find nothing recoverable/
      # The game refused the part: too high, or the target has lost it.
      REFUSED = /You cannot aim that high!|does not have a head!|is already missing that!|does not have a (?:right|left) leg!|does not have a (?:right|left) arm!/i

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param part [String] the body part to hurl at
      # @param state [Engage::State] for `bond_returned`
      # @param expected_ids [Array<String>, nil] hands before a managed throw
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, part:, state:, expected_ids: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @part = part
        @state = state
        @expected_ids = expected_ids
      end

      # @return [Symbol] :ok, or :dead, :muckled
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # @return [Actions::Result] :part_refused on a REFUSED line, the HURL's own
      #   failure, else the RecoverHurl Result
      def perform
        @state.bond_returned = false
        room = @world.room.id
        result = send_and_match("hurl ##{@target.id} #{@part}", Regexp.union(THROWN, NOTHING, REFUSED), timeout: 2)
        return result unless result.success?
        return Result.new(status: :failed, reason: :part_refused, line: result.line) if result.line =~ REFUSED

        if result.line =~ THROWN && !@expected_ids
          hold = 6 - me.rt
          settle_rt
          sleep hold if hold.positive?
        end
        RecoverHurl.new(@world, state: @state, room: room, expected_ids: @expected_ids, interrupt: @interrupt).call
      end
    end

    # cmd_recover: RECOVER HURL until the weapon is back or the game
    # says there is nothing, in the room it was thrown from. The throw and
    # the recovery are one action, so we are still there; if we are not
    # (bigshot go2s back), the weapon is a disarm for Cleanse to go after.
    #
    # @bigshot cmd_recover
    class RecoverHurl < Base
      # cmd_dhurl's six-second flight window, before RECOVER HURL.
      FLIGHT_SECONDS = 6
      # Managed recovery's total observation and recovery budget.
      RETURN_TIMEOUT = 10
      # Every answer to RECOVER HURL: not yet visible, recovered, flown
      # back, no free hand, nothing to recover.
      ANSWERS = /You know .+ is around here somewhere, but you don't see it\.|You spy a .+ and recover it|A .+ rises out of the shadows and flies back to your waiting hand!|In order to recover your hurled weapon, you'll need to have a free hand\.|You find nothing recoverable\./

      # @param world [World]
      # @param state [Engage::State] `bond_returned` ends the loop early
      # @param room [Integer, nil] the room the weapon was thrown from
      # @param expected_ids [Array<String>, nil] verify original hand identities
      # @param timeout [Numeric] managed recovery deadline in seconds
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, state:, room: nil, expected_ids: nil, timeout: RETURN_TIMEOUT, **opts)
        super(world, **opts)
        @state = state
        @room = room
        @expected_ids = expected_ids
        @timeout = timeout
        if expected_ids
          external_interrupt = @interrupt
          @interrupt = lambda do
            external_interrupt&.call || me.dead? || me.muckled? ||
              (@room && @world.room.id != @room) || (@deadline && clock_now >= @deadline)
          end
        end
      end

      # Include the shared roundtime and send waits in the managed deadline.
      #
      # @return [Actions::Result]
      def call
        return super unless @expected_ids

        @started_at = clock_now
        @deadline = @started_at + @timeout
        result = super
        if result.failed? && clock_now >= @deadline
          Result.new(status: :timeout, reason: :equipment_return_timeout,
                     line: "original hand item IDs #{@expected_ids.join(', ')} were not restored")
        else
          result
        end
      end

      # @return [Symbol] :ok, or :dead, :not_in_throw_room
      def preconditions
        return :dead if me.dead?
        return :not_in_throw_room if @room && @world.room.id != @room

        :ok
      end

      # Up to eight RECOVER HURLs, half a second apart.
      #
      # @return [Actions::Result] success :bond_return or :recovered; failed
      #   :not_recovered, :interrupted, or the send's own failure
      def perform
        return perform_managed if @expected_ids

        8.times do
          return Result.new(status: :success, reason: :bond_return) if @state.bond_returned
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          settle_rt
          result = send_and_match('recover hurl', ANSWERS, timeout: 5)
          return result unless result.success?
          return Result.new(status: :success, reason: :recovered, line: result.line) if result.line =~ /You spy a .+ and recover it|flies back to your waiting hand/
          return Result.new(status: :failed, reason: :not_recovered, line: result.line) if result.line =~ /free hand|nothing recoverable/

          sleep 0.5
        end
        Result.new(status: :failed, reason: :not_recovered)
      end

      private

      def perform_managed
        departed_id = nil
        recovered = false
        recover_at = @started_at + FLIGHT_SECONDS
        loop do
          ids = [@world.hands.right&.id, @world.hands.left&.id].compact.map(&:to_s)
          missing = @expected_ids - ids
          if missing.size > 1
            return Result.new(status: :failed, reason: :throw_hand_ambiguous,
                              line: 'multiple original hand items disappeared during the throw')
          end
          departed_id ||= missing.first
          if missing.empty? && (departed_id || @state.bond_returned || recovered || clock_now >= @started_at + FLIGHT_SECONDS)
            return Result.new(status: :success, reason: :recovered)
          end
          return Result.new(status: :failed, reason: :not_in_throw_room) if @room && @world.room.id != @room
          return Result.new(status: :failed, reason: :interrupted) if interrupted?

          # Preserve cmd_dhurl's flight window, but release every event wait
          # for stop, danger, room changes, or a verified automatic return.
          if clock_now >= recover_at && !recovered && !@state.bond_returned
            return Result.new(status: :failed, reason: :not_recovered, line: 'no free hand for the hurled weapon') if ids.size == 2

            settle_rt
            return Result.new(status: :failed, reason: :interrupted) if interrupted?

            result = send_and_match('recover hurl', ANSWERS, timeout: [5, @deadline - clock_now].min)
            return result unless result.success?
            if result.line =~ /free hand|nothing recoverable/
              return Result.new(status: :failed, reason: :not_recovered, line: result.line)
            end
            recovered = result.line =~ /You spy a .+ and recover it|flies back to your waiting hand/
            recover_at = clock_now + 0.5
          end
          Events.await(:bond_return, timeout: [0.1, @deadline - clock_now].min)
        end
      end
    end

    # cmd_caststop: force_cast then STOP the spell.
    #
    # @bigshot cmd_caststop
    class CastStop < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param spell [Integer] the spell number to cast and stop
      # @param extra [String, nil] appended to the cast
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, spell:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @num = spell
        @extra = extra
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[@num]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success, :cast_stopped; neither answer is read
      def perform
        @world.spell[@num].force_cast("##{@target.id}", @extra.to_s)
        send_through_ladder("stop #{@num}")
        Result.new(status: :success, reason: :cast_stopped)
      end
    end

    # cmd_depress: RENEW 1015, else incant it; once per room.
    #
    # @bigshot cmd_depress
    class Depress < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param already [Boolean] true when this routine line already ran in the room
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, already: false, **opts)
        super(world, target: target, **opts)
        @target = target
        @already = already
      end

      # @return [Symbol] :ok, or :dead, :room_affected, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?
        return :room_affected if @already

        s = @world.spell[1015]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success :renewed or :sung, else the RENEW's failure
      def perform
        result = send_and_match('renew 1015', /Renewing "Song of Depression" for 6 mana\.|But you are not singing that spellsong\./, timeout: 3)
        if result.success? && result.line =~ /not singing/
          @world.spell[1015].force_incant if @world.spell[1015].affordable?
          return Result.new(status: :success, reason: :sung)
        end
        result.success? ? Result.new(status: :success, reason: :renewed) : result
      end
    end

    # cmd_unravel: force_cast 1013 and read the song's answer.
    #
    # @bigshot cmd_unravel
    class Unravel < Base
      include CombatRt

      # Every answer to the song: already singing, absorbed, resonating,
      # the mana gain, nothing to pull at, the thread fading, the
      # concentration break, and the two target-gone lines.
      ANSWERS = Regexp.union(
        /You are already singing that spellsong\./,
        /The evanescent shield shrouding .* flares to life and absorbs the essence of the spell, dissipating it harmlessly\./,
        /You feel your song resonate around the .*, pulling at the threads of mana within\./,
        /You feel your song touch the magic surrounding the .+ and begin to resonate, pulling at the threads of the .+'s control\./,
        /The silvery tendril continues to wend its way away from the /,
        /You gain \d+ mana!/,
        /You feel your song echo around the .* as if it had entered a vast empty chamber\./,
        /The serpentine thread stretching between you and the (.*) fades, then disappears\./,
        /Your concentration on unravelling the threads of mana is broken\./,
        /A little bit late for that don't you think\?/,
        /What were you referring to\?/
      )

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param extra [String, nil] appended to the cast
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, extra: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @extra = extra
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[1013]
        return :unknown_spell unless s&.known?
        return :unaffordable unless s.affordable?

        :ok
      end

      # Up to six casts: an "already singing" answer stops the song and
      # tries again; a resonance is stopped and counts as done.
      #
      # @return [Actions::Result] success :unravelled or :nothing_to_unravel;
      #   failed :target_gone, :cast_refused, :interrupted, :unravel_loop
      def perform
        6.times do
          settle_rt
          answer = @world.spell[1013].force_cast("##{@target.id}", @extra.to_s, ANSWERS).to_s
          case answer
          when /You are already singing that spellsong\./, /The silvery tendril continues/
            send_through_ladder('stop 1013')
          when /You feel your song resonate|You feel your song touch|You gain \d+ mana!/
            settle_rt
            send_through_ladder('stop 1013')
            return Result.new(status: :success, reason: :unravelled, line: answer)
          when /concentration on unravelling .* is broken|vast empty chamber/
            return Result.new(status: :success, reason: :nothing_to_unravel, line: answer)
          when /What were you referring to\?|A little bit late/
            send_through_ladder('release')
            return Result.new(status: :failed, reason: :target_gone, line: answer)
          else
            return Result.new(status: :failed, reason: :cast_refused, line: answer)
          end
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
        end
        Result.new(status: :failed, reason: :unravel_loop)
      end
    end

    # cmd_stomp: 909 up, then STOMP with five mana.
    #
    # @bigshot cmd_stomp
    class Stomp < Base
      include CombatRt

      # @return [Symbol] :ok, or :dead, :unknown_spell
      def preconditions
        return :dead if me.dead?

        @world.spell[909]&.known? ? :ok : :unknown_spell
      end

      # @return [Actions::Result] the STOMP's first answer line; :unaffordable
      #   when 909 is down and cannot be channelled, :low_mana under five
      def perform
        s = @world.spell[909]
        unless s.active?
          return Result.new(status: :failed, reason: :unaffordable) unless s.affordable?

          s.force_channel
          settle_rt
        end
        return Result.new(status: :failed, reason: :low_mana) if me.mana < 5

        send_and_match('stomp', /.*/, timeout: 3)
      end
    end

    # cmd_leech: 516 when its cooldown has under fifteen seconds.
    #
    # @bigshot cmd_leech
    class Leech < Base
      include CombatRt

      # @return [Symbol] :ok, or :dead, :unknown_spell, :cooldown, :unaffordable
      def preconditions
        return :dead if me.dead?

        s = @world.spell[516]
        return :unknown_spell unless s&.known?
        return :cooldown unless me.cooldown_time_left('Mana Leech') < 15
        return :unaffordable unless s.affordable?

        :ok
      end

      # @return [Actions::Result] success, :leech; the cast's answer is not read
      def perform
        @world.spell[516].cast
        Result.new(status: :success, reason: :leech)
      end
    end

    # cmd_jewel: GEMSTONE ACTIVATE by mnemonic, off cooldown.
    #
    # @bigshot cmd_jewel
    class Jewel < Base
      include CombatRt

      # bigshot's mnemonic => the property's cooldown name.
      JEWELS = {
        'bloodboil' => 'Blood Boil', 'spellblade' => "Spellblade's Fury", 'arcascend' => "Arcanist's Ascendancy",
        'geospite' => "Geomancer's Spite", 'forceofwill' => 'Force of Will', 'arcaneintensity' => 'Arcane Intensity',
        'arcaneopus' => 'Arcane Opus', 'bloodsiphon' => 'Blood Siphon', 'bloodwell' => 'Blood Wellspring',
        'epossess' => 'Evanescent Possession', 'manawellspring' => 'Mana Wellspring', 'spiritwell' => 'Spirit Wellspring',
        'stamwell' => 'Stamina Wellspring', 'terrortribute' => "Terror's Tribute", 'arcblade' => "Arcanist's Blade",
        'arcwill' => "Arcanist's Will", 'imaerabalm' => "Imaera's Balm", 'reckless' => 'Reckless Precision',
        'unearthchains' => 'Unearthly Chains', 'witchhunt' => "Witchhunter's Ascendancy", 'manashield' => 'Mana Shield',
        'arcaneaegis' => 'Arcane Aegis'
      }.freeze
      # Every answer to GEMSTONE ACTIVATE: the property refusals, Cast's
      # result lines, and the general cannot-act lines.
      ANSWERS = Regexp.union(
        /^That property isn't ready yet\./, /^You don't have that property equipped\./, /^You fail to find a target\./,
        /^You have not yet unlocked Gemstones\./, Cast::CAST, Cast::BLOCKED, Cast::NO_TARGET, Cast::CANNOT_PREPARE, Cast::FIZZLED,
        /keeps? the spell from working\./, /^As you focus on your magic, your vision swims/, /^And give yourself away!  Never!$/,
        /^You are unable to do that right now\.$/, /^You don't seem to be able to move to do that\.$/
      )

      # @param world [World]
      # @param mnemonic [String] a JEWELS key
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, mnemonic:, **opts)
        super(world, **opts)
        @mnemonic = mnemonic.to_s.downcase
      end

      # @return [Symbol] :ok, or :dead, :unknown_jewel, :cooldown
      def preconditions
        return :dead if me.dead?
        return :unknown_jewel unless JEWELS.key?(@mnemonic)
        return :cooldown if me.cooldown_active?(JEWELS[@mnemonic])

        :ok
      end

      # @return [Actions::Result] the first ANSWERS line, refusals included
      def perform = send_and_match("gemstone activate #{@mnemonic}", ANSWERS, timeout: 2)
    end

    # cmd_briar: MEASURE each briar weapon, RAISE it at 100%.
    #
    # @bigshot cmd_briar
    class Briar < Base
      # @param world [World]
      # @param weapon [String] the weapon noun, in hand or in the inventory
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, weapon:, **opts)
        super(world, **opts)
        @weapon = weapon
      end

      # @return [Symbol] :ok, or :dead, :active (9105 already up)
      def preconditions
        return :dead if me.dead?
        return :active if me.spell_active?(9105)

        :ok
      end

      # @return [Actions::Result] success :raised or :not_ready; failed :no_weapon
      def perform
        items = [@world.hands.right, @world.hands.left].select { |h| h&.id && h.noun.to_s == @weapon }
        items += inventory.select { |i| i.noun.to_s == @weapon }
        return Result.new(status: :failed, reason: :no_weapon) if items.empty?

        raised = 0
        items.each do |item|
          lines = measure(item.id)
          next unless lines.any? { |l| l =~ /to be about (\d+) percent\./i && Regexp.last_match(1).to_i == 100 }

          send_through_ladder("raise ##{item.id}")
          raised += 1
        end
        Result.new(status: :success, reason: raised.positive? ? :raised : :not_ready)
      end

      private

      def inventory
        Array(::GameObj.inv)
      rescue StandardError
        []
      end

      def measure(id)
        ::Lich::Util.quiet_command_xml("measure ##{id}", /^You gaze intently|^Now, why are you trying to measure/, /<prompt time=/)
      rescue StandardError
        []
      end
    end

    # cmd_assume: PREP or EVOKE 650, ASSUME the first aspect, then
    # the second, or CAST the prepared 650.
    #
    # @bigshot cmd_assume
    class Assume < Base
      include CombatRt

      # ASSUME took, fully or not.
      ASSUMED = /^You concentrate your focus upon the Aspect|^You feel that you will not be able to fully concentrate upon the Aspect/i

      # @param world [World]
      # @param aspect [String] the first aspect (see Engage::Routines::ASPECTS)
      # @param extra [String] the second aspect, or "evoke" to EVOKE 650
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, aspect:, extra:, **opts)
        super(world, **opts)
        @aspect = aspect.to_s.downcase
        @extra = extra.to_s.downcase
      end

      # @return [Symbol] :ok, or :dead, :unknown_spell, :bad_aspect, :cooldown
      #   (both aspects), :active (either aspect up)
      def preconditions
        return :dead if me.dead?
        return :unknown_spell unless @world.spell[650]&.known?
        return :bad_aspect unless @aspect =~ Engage::Routines::ASPECTS
        # The second word is another aspect, "evoke", or absent. Only a
        # real aspect names a cooldown effect: "Aspect of the Evoke
        # Cooldown" is not a spell, and Lich's Spell[] answers nil for it.
        return :cooldown if second_aspect && me.spell_active?("Aspect of the #{@aspect.capitalize} Cooldown") && me.spell_active?("Aspect of the #{second_aspect.capitalize} Cooldown")
        return :active if me.effect_active?("Aspect of the #{@aspect.capitalize}") || (second_aspect && me.effect_active?("Aspect of the #{second_aspect.capitalize}"))

        :ok
      end

      # @return [Actions::Result] success :assumed, :evoked or :cast; failed
      #   :not_prepared, :cooldown
      def perform
        s = @world.spell[650]
        prep = me.prepared_spell.to_s
        send_through_ladder('release') if prep != 'None' && prep != 'Assume Aspect'
        settle_rt
        first = false
        unless me.effect_active?('Assume Aspect') || me.effect_active?('650') || me.prepared_spell.to_s == 'Assume Aspect'
          if @extra =~ /evoke/
            s.force_evoke if s.affordable?
          else
            send_through_ladder('prep 650') if s.affordable?
          end
          first = true
        end
        return Result.new(status: :failed, reason: :not_prepared) unless me.prepared_spell.to_s == 'Assume Aspect' || me.effect_active?('Assume Aspect') || me.effect_active?('650')

        if !me.spell_active?("Aspect of the #{@aspect.capitalize} Cooldown") && (first || me.mana >= 25)
          send_and_match("assume #{@aspect}", ASSUMED, timeout: 1)
          Result.new(status: :success, reason: :assumed)
        elsif @extra =~ /evoke/ && (first || me.mana >= 25)
          # bigshot returns bare here (cmd_assume 5651) and cast_signs moves
          # to the next sign. Nothing is sent - the evoke happened above, on
          # the first pass only - so this is a skip, not a success. As a
          # success it read as a done thing on every later tick.
          Result.new(status: :skipped, reason: :evoked)
        elsif second_aspect && !me.spell_active?("Aspect of the #{second_aspect.capitalize} Cooldown") && (first || me.mana >= 25)
          send_and_match("assume #{second_aspect}", ASSUMED, timeout: 1)
          Result.new(status: :success, reason: :assumed)
        elsif me.prepared_spell.to_s == 'Assume Aspect'
          send_through_ladder('cast') if s.affordable?
          Result.new(status: :success, reason: :cast)
        else
          Result.new(status: :failed, reason: :cooldown)
        end
      end

      private

      # The routine's second word when it names another aspect. "evoke"
      # and a missing word are not aspects, so they name no cooldown
      # effect: building one gave Lich a spell name it does not know, and
      # Spell[] answers nil for it.
      #
      # @return [String, nil]
      def second_aspect = @extra =~ Engage::Routines::ASPECTS ? @extra : nil
    end

    # cmd_throw: stow, THROW #id, refill; never at a creature lying down.
    #
    # @bigshot cmd_throw
    class Throw < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id` and `status`)
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, **opts)
        super(world, target: target, **opts)
        @target = target
      end

      # @return [Symbol] :ok, or :dead, :target_down
      def preconditions
        return :dead if me.dead?
        return :target_down if @target.status.to_s == 'lying down'

        :ok
      end

      # @return [Actions::Result] the THROW's Result; the hands are refilled
      #   through Lich's Stash either way
      def perform
        send_through_ladder('stow all')
        result = send_and_match("throw ##{@target.id}", /^You attempt to throw a .*!$/, timeout: 1)
        settle_rt
        ::Lich::Stash.equip_hands(both: true) rescue nil
        result
      end
    end

    # cmd_wield: the item into the hand. Lich's Stash.wield
    # (lich-5 #1579) finds it anywhere in the inventory tree (the
    # inventoryManager snapshot, closed containers included), stores what
    # the hand holds on the STORE settings, opens the way to it, gets or
    # removes it, and confirms it arrived; bigshot's STORE-then-GET pair
    # assumed all of that.
    #
    # @bigshot cmd_wield
    class Wield < Base
      # @param world [World]
      # @param noun [String] the item's noun
      # @param hand [String] "left", "right", or "" for Stash's choice
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, noun:, hand: '', **opts)
        super(world, **opts)
        @noun = noun
        @hand = hand.to_s
      end

      # @return [Symbol] :ok, or :dead, :already_wielded
      def preconditions
        return :dead if me.dead?
        return :already_wielded if (@hand.empty? || @hand == 'right') && @world.hands.right.noun.to_s == @noun
        return :already_wielded if @hand == 'left' && @world.hands.left.noun.to_s == @noun

        :ok
      end

      # @return [Actions::Result] success :wielded with the item's name as the
      #   line; failed :not_wielded with Stash's error message
      def perform
        item = wield(@noun, hand: @hand.empty? ? nil : @hand.to_sym)
        Result.new(status: :success, reason: :wielded, line: item.name.to_s)
      rescue StandardError => e
        Result.new(status: :failed, reason: :not_wielded, line: e.message)
      end

      # The Stash seam (stubbed in specs).
      #
      # @param noun [String]
      # @param hand [Symbol, nil] :left, :right, or nil
      # @return [Object] the item Stash put in hand (responds to `name`)
      # @raise [StandardError] whatever Stash raises when it cannot
      def wield(noun, hand:) = ::Lich::Stash.wield(noun, hand: hand)
    end

    # cmd_store: Lich's Stash.stash_hands, the STORE settings
    # (ReadyList, StowList) applied with each item confirmed away.
    #
    # @bigshot cmd_store
    class Store < Base
      # @param world [World]
      # @param hand [String] "left", "right" or "both"; empty means both
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, hand: 'both', **opts)
        super(world, **opts)
        @hand = hand.to_s.empty? ? 'both' : hand.to_s
      end

      # @return [Symbol] :ok, or :dead, :empty (nothing in the named hand or hands)
      def preconditions
        return :dead if me.dead?
        return :empty if @hand == 'right' && @world.hands.right.id.nil?
        return :empty if @hand == 'left' && @world.hands.left.id.nil?
        return :empty if @hand == 'both' && @world.hands.right.id.nil? && @world.hands.left.id.nil?

        :ok
      end

      # @return [Actions::Result] success :stored; failed :not_stored with
      #   Stash's error message
      def perform
        stash(@hand)
        Result.new(status: :success, reason: :stored)
      rescue StandardError => e
        Result.new(status: :failed, reason: :not_stored, line: e.message)
      end

      # The Stash seam (stubbed in specs): `stash_hands(left: true)` and so on.
      #
      # @param hand [String] "left", "right" or "both"
      # @return [Object] whatever Stash.stash_hands returns
      # @raise [StandardError] whatever Stash raises when it cannot
      def stash(hand) = ::Lich::Stash.stash_hands(**{ hand.to_sym => true })
    end

    # cmd_nudge_weapons: carry each weapon on the floor one room
    # over and come back, sheathing first when both hands are full.
    #
    # @bigshot cmd_nudge_weapons
    class NudgeWeapons < Base
      # Room exits are the long names; Lich's reverse_direction takes the
      # short ones and, handed a long one, falls through to comparisons
      # that call the bare direction verbs (n, ne...), which would move us.
      REVERSE = { 'north' => 'south', 'south' => 'north', 'east' => 'west', 'west' => 'east', 'northeast' => 'southwest', 'southwest' => 'northeast',
                  'northwest' => 'southeast', 'southeast' => 'northwest', 'up' => 'down', 'down' => 'up', 'out' => 'out' }.freeze

      # @param world [World]
      # @param stance [#call, nil] Engage's stance setter, given a stance name
      # @param wander_stance [String, nil] the profile's wander stance, set before each carry
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, stance: nil, wander_stance: nil, **opts)
        super(world, **opts)
        @stance = stance
        @wander_stance = wander_stance
      end

      # @return [Symbol] :ok, or :dead, :no_exit
      def preconditions
        return :dead if me.dead?
        return :no_exit if Array(@world.room.exits).empty?

        :ok
      end

      # @return [Actions::Result] success :nudged or :nothing_to_nudge; failed
      #   :hands_full, :no_way_back, :could_not_step, :could_not_return
      def perform
        moved = 0
        # Lich's item typing (gameobj-data) says what is a weapon.
        Array(@world.room.loot).select { |i| i.type.to_s.include?('weapon') }.each do |item|
          @stance&.call(@wander_stance) if @wander_stance
          sheathed = false
          if @world.hands.right.id && @world.hands.left.id
            sheathed = true
            send_through_ladder('sheath')
            return Result.new(status: :failed, reason: :hands_full) if @world.hands.right.id && @world.hands.left.id
          end
          # Every weapon goes out the SAME exit, deliberately. The point of
          # nudging is to clear this room - an area spell such as 720 sends
          # loose items in the room flying, and bystanders wear the result -
          # so one dumping ground next door beats seeding junk down every
          # exit we might walk back through.
          #
          # bigshot reads the same way despite appearances: cmd_nudge_weapons
          # 5350 does `checkpaths.shift`, but Lich rebuilds that array on
          # every call (global_defs.rb 886 collects a fresh one), so the
          # shift mutates a throwaway and always yields the first exit too.
          dir = Array(@world.room.exits).first
          back = REVERSE[dir]
          return Result.new(status: :failed, reason: :no_way_back) if back.nil?

          send_through_ladder("get ##{item.id}")
          there = Move.new(@world, way: dir, interrupt: @interrupt).call
          return Result.new(status: :failed, reason: :could_not_step, line: dir) unless there.success?

          send_through_ladder("drop ##{item.id}")
          home = Move.new(@world, way: back, interrupt: @interrupt).call
          return Result.new(status: :failed, reason: :could_not_return, line: back) unless home.success?

          send_through_ladder('gird') if sheathed
          moved += 1
        end
        Result.new(status: :success, reason: moved.positive? ? :nudged : :nothing_to_nudge)
      end
    end

    # cmd_berserk: wander stance and 9607 with twenty stamina, else
    # TARGET RANDOM and KILL.
    #
    # @bigshot cmd_berserk
    class Berserk < Base
      include CombatRt

      # @param world [World]
      # @param stance [#call, nil] Engage's stance setter, given a stance name
      # @param wander_stance [String, nil] the profile's wander stance, set before 9607
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, stance: nil, wander_stance: nil, **opts)
        super(world, **opts)
        @stance = stance
        @wander_stance = wander_stance
      end

      # @return [Symbol] :ok, or :dead
      def preconditions = me.dead? ? :dead : :ok

      # With the stamina: cast 9607 and hold (two minutes at most) while it
      # runs. Without: TARGET RANDOM, KILL.
      #
      # @return [Actions::Result] success :berserked or :kill_random
      def perform
        if me.stamina >= 20
          @stance&.call(@wander_stance) if @wander_stance
          @world.spell[9607].cast
          sleep 5
          deadline = clock_now + 120
          sleep 0.5 while me.spell_active?(9607) && clock_now < deadline && !interrupted?
          Result.new(status: :success, reason: :berserked)
        else
          send_through_ladder('target random')
          send_through_ladder('kill')
          Result.new(status: :success, reason: :kill_random)
        end
      end
    end

    # cmd_volnsmite: SMITE an undead or noncorporeal target until it
    # is smote or the game says it is done.
    #
    # @bigshot cmd_volnsmite
    class Smite < Base
      include CombatRt

      # @param world [World]
      # @param target [Object] the creature (responds to `id` and `type`)
      # @param state [Engage::State] for the smote-id list
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, state:, **opts)
        super(world, target: target, **opts)
        @target = target
        @state = state
      end

      # @return [Symbol] :ok, or :dead, :already_smote, :not_undead
      def preconditions
        return :dead if me.dead?
        return :already_smote if @state.smite_done?.include?(@target.id.to_s)

        types = @target.type.to_s.split(',')
        return :not_undead unless types.include?('undead') || types.include?('noncorporeal')

        :ok
      end

      # Up to six SMITEs a second apart, until the target is gone or the
      # game says the job is done.
      #
      # @return [Actions::Result] success :already_smote, :smote or :smite_ended;
      #   failed :interrupted, :referent_missing
      def perform
        6.times do
          return Result.new(status: :failed, reason: :interrupted) if interrupted?
          break unless target_still_live?

          result = send_and_match("smite ##{@target.id}", /^Roundtime|^What were you referring to\?$|^It looks like somebody already did the job for you\.$/, timeout: 1)
          if result.success? && result.line =~ /already did the job/
            @state.smite_done? << @target.id.to_s
            return Result.new(status: :success, reason: :already_smote)
          end
          return Result.new(status: :failed, reason: :referent_missing) if result.success? && result.line =~ /What were you/

          sleep 1
        end
        Result.new(status: :success, reason: :smite_ended)
      end
    end

    # cmd_ranged: AIM at the profile's next part (skipping one an
    # arrow is stuck in, or a head or eye the target has lost), FIRE, stow
    # a weapon the game refuses to fire, rest on unblessed ammo.
    #
    # @bigshot cmd_ranged
    class Ranged < Base
      include CombatRt

      # Every answer to FIRE: the roundtime, the refusals, and unblessed ammo.
      ANSWERS = /round(?:time)?|You cannot|Could not find|seconds|Get what\?|but it has no effect/i

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param policy [Engage::Policy] `archery_aim` parts and `ammo_container`
      # @param state [Engage::State] the aim index, stuck list and location
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, policy:, state:, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
      end

      # @return [Symbol] :ok, or :dead, :muckled, :too_injured
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?
        return :too_injured unless me.able_to_use_ranged? # Lich's Injured: arms and hands

        :ok
      end

      # @return [Actions::Result] success on a roundtime line (the aim resets);
      #   failed :cannot_fire (ammo stowed), :ammo_no_effect (:ammo_no_effect
      #   on the bus), :fire_refused, or the FIRE's own failure
      def perform
        aim
        result = send_and_match("fire ##{@target.id}", ANSWERS, timeout: 2)
        return result unless result.success?

        line = result.line
        if line =~ /You cannot fire/
          stow_weapon
          Result.new(status: :failed, reason: :cannot_fire, line: line)
        elsif line =~ /but it has no effect/
          Events.emit(:ammo_no_effect)
          Result.new(status: :failed, reason: :ammo_no_effect, line: line)
        elsif line =~ /round(?:time)?/i
          @state.archery_aim = 0
          @state.archery_stuck.clear
          result
        else
          Result.new(status: :failed, reason: :fire_refused, line: line)
        end
      end

      private

      def aim
        parts = Array(@policy.archery_aim)
        return if parts.empty?

        @state.archery_aim = @state.archery_aim.to_i + 1 if @state.archery_stuck.any? { |s| @state.archery_location && s =~ /#{Regexp.escape(@state.archery_location)}/i }
        if @state.archery_aim > parts.length
          @state.archery_aim = 0
          @state.archery_stuck.clear
        end
        part = parts[@state.archery_aim]
        return if part.nil?

        vitals_skip(parts) if %w[head neck left\ eye right\ eye].include?(part)
        part = parts[@state.archery_aim]
        return if part.nil?
        return if @state.archery_location && part =~ /#{Regexp.escape(@state.archery_location)}/i

        send_through_ladder("aim #{part}")
      end

      # check_target_vitals: skip a part the target has already lost
      def vitals_skip(parts)
        info = vitals
        return if info.nil?

        part = parts[@state.archery_aim]
        lost = (part == 'head' && info =~ /severe head trauma and bleeding from .* ears/) ||
               (part == 'neck' && info =~ /snapped bones and serious bleeding from .* neck/) ||
               (part == 'left eye' && info =~ /blinded left eye/) ||
               (part == 'right eye' && info =~ /blinded right eye/)
        @state.archery_aim += 1 if lost
      end

      def vitals
        lines = ::Lich::Util.issue_command("look ##{@target.id}", /You see|I could not find/, quiet: true, silent: true)
        line = lines.find { |l| l =~ %r{(?:he|she|it)</a><popBold/> has (.*)}i }
        line && line[%r{(?:he|she|it)</a><popBold/> has (.*)}i, 1]
      rescue StandardError
        nil
      end

      # The bow is in the left hand and FIRE draws the ammo into the
      # right, so something in the right hand after a refused fire is
      # ammo that got there by hand (GET 1 ARROW, FIRE) and is in the
      # way. Only ammo is stowed; bigshot's version stowed whatever the
      # right hand held, a crossbow included.
      def stow_weapon
        weapon = @world.hands.right
        return if weapon.id.nil? || weapon.type.to_s !~ /\bammo\b/

        result = send_and_match("stow ##{weapon.id}", /put|closed/, timeout: 3)
        return unless result.success? && result.line =~ /closed/

        # The profile's ammo_container first (bigshot's key); with none
        # named, the closed container STOW just refused is the game's own
        # STOW DEFAULT, which Lich's StowList reads.
        container = @policy.ammo_container ? me.inventory_named(@policy.ammo_container) : @world.stow_default
        return if container.nil?

        stash_into(container, weapon)
      end

      # Lich's Stash (lich-5 #1579): open the container, then drag the
      # weapon in and wait for it to leave the hand. False when either
      # step fails, where the raw open-and-put pair assumed success.
      def stash_into(container, weapon)
        ::Lich::Stash.open_container(container.id) && ::Lich::Stash.add_to_bag(container, weapon) ? true : false
      rescue StandardError
        false
      end
    end

    # cmd_dislodge: CMAN DISLODGE the first listed location an arrow
    # is stuck in, on the creature it stuck in.
    #
    # @bigshot cmd_dislodge
    class Dislodge < Base
      include CombatRt

      # Every answer to CMAN DISLODGE: the two successes, the refusals, roundtime.
      ANSWERS = /attempting to dislodge|suitable weapons lodged|You can't reach|awkward proposition|little bit late|still stunned|too injured|what\?|round(?:time)?|You cannot|Could not find|seconds|You manage to dislodge|You skillfully wrench/i

      # @param world [World]
      # @param target [Object] the creature (responds to `id` and `status`)
      # @param state [Engage::State] `dislodge_target` and `dislodge_locations`
      # @param locations [String] the routine's locations, space-separated, in order
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, state:, locations:, **opts)
        super(world, target: target, **opts)
        @target = target
        @state = state
        @locations = locations.to_s.split(/ /, 9)
      end

      # Also picks the location: the first listed one an arrow is stuck in.
      #
      # @return [Symbol] :ok, or :dead, :unavailable, :wrong_target, :nothing_lodged
      def preconditions
        return :dead if me.dead?
        return :unavailable unless cman_available?
        return :wrong_target if @target.id.to_s != @state.dislodge_target.to_s

        @where = @locations.find { |loc| @state.dislodge_locations.include?(loc) }
        @where ? :ok : :nothing_lodged
      end

      # @return [Actions::Result] success :dislodged (the location dropped from
      #   the state, all of it on a dead target); failed :dislodge_refused or
      #   the send's own failure
      def perform
        result = send_and_match("cman dislodge ##{@target.id} #{@where}", ANSWERS, timeout: 2)
        return result unless result.success?

        if result.line =~ /You manage to dislodge|You skillfully wrench/
          @state.dislodge_locations.delete(@where)
          if @target.status.to_s =~ /dead|gone/
            @state.dislodge_locations.clear
            @state.dislodge_target = nil
          end
          Result.new(status: :success, reason: :dislodged, line: result.line)
        else
          Result.new(status: :failed, reason: :dislodge_refused, line: result.line)
        end
      end

      private

      def cman_available?
        ::Lich::Gemstone::CMan.available?('Dislodge')
      rescue StandardError
        false
      end
    end

    # cmd_wand: the next fresh wand from its container into hand,
    # WAVE it at the target in the offensive stance, drop or store a wand
    # that gave nothing.
    #
    # @bigshot cmd_wand
    class Wand < Base
      include CombatRt

      # Every answer to WAVE: a roll, a hurl, and the target and condition refusals.
      WAVED = /d100|You hurl|is already dead|You do not see that here|You are in no condition|I could not find/
      # GETs allowed in one tick before the action gives up, so a GET the
      # game answers but in_hand? cannot recognise ends the tick instead of
      # spinning inside it.
      GET_TRIES = 6

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param policy [Engage::Policy] `wand` list, `fresh_wand_container`,
      #   `dead_wand_container`, `hunting_stance`
      # @param state [Engage::State] `wand_index`, the cursor into the list
      # @param stance [#call, nil] Engage's stance setter, given a stance name
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, policy:, state:, stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
        @stance = stance
      end

      # @return [Symbol] :ok, or :dead, :no_container, :no_wands
      def preconditions
        return :dead if me.dead?
        return :no_container if @policy.fresh_wand_container.to_s.empty?
        return :no_wands if Array(@policy.wand).empty?

        :ok
      end

      # @return [Actions::Result] the WAVE's Result on a WAVED line; failed
      #   :wand_timeout, :no_fresh_wands (also on the bus), :too_injured
      #   (:too_injured_for_wands on the bus), :dead_wand (dropped or stored)
      def perform
        wand = current_wand
        # The cursor is kept across fights and only ever moves forward, so
        # a run that exhausted the list leaves it past the end. Answer that
        # here rather than interpolating the nil into a GET: the old code
        # sent `get  from my <container>`, drew 'Get what?', bumped the
        # cursor again and returned - every wand line for the rest of the
        # hunt burning a send on a command that could not work.
        if wand.nil?
          Events.emit(:no_fresh_wands)
          return Result.new(status: :failed, reason: :no_fresh_wands)
        end

        # bigshot's loop has the same shape but a live hand check each pass
        # (cmd_wand 4792). A GET that answers 'You remove' for an item whose
        # name in_hand? does not recognise used to spin with no counter and
        # no deadline, inside one tick.
        tries = 0
        until in_hand?(wand)
          return Result.new(status: :failed, reason: :wand_not_in_hand) if (tries += 1) > GET_TRIES

          result = send_and_match("get #{wand} from my #{@policy.fresh_wand_container}", /You remove|You slip|Get what/, timeout: 3)
          return Result.new(status: :failed, reason: :wand_timeout) unless result.success?

          if result.line =~ /Get what/
            @state.wand_index = @state.wand_index.to_i + 1
            wand = current_wand
            if wand.nil?
              Events.emit(:no_fresh_wands)
              return Result.new(status: :failed, reason: :no_fresh_wands)
            end
          end
        end

        @stance&.call('offensive')
        result = send_and_match("wave my #{wand} at ##{@target.id}", WAVED, timeout: 3)
        @stance&.call(@policy.hunting_stance) if @policy.hunting_stance
        if result.success? && result.line =~ /You are in no condition/
          Events.emit(:too_injured_for_wands)
          return Result.new(status: :failed, reason: :too_injured, line: result.line)
        end
        # bigshot discards on `result.nil?` alone - no answer at all, so the
        # wand is spent (cmd_wand 4816). `unless success?` also caught
        # :interrupted (the engine stopping), :dead and :no_response, and
        # threw away a working wand on each.
        if result.status == :timeout
          if @policy.dead_wand_container.to_s.empty?
            send_through_ladder("drop my #{wand}")
          else
            send_through_ladder("put my #{wand} in my #{@policy.dead_wand_container}")
          end
          return Result.new(status: :failed, reason: :dead_wand)
        end
        return result unless result.success?
        result
      end

      private

      def current_wand = Array(@policy.wand)[@state.wand_index.to_i]

      def in_hand?(wand)
        return false if wand.nil?

        pattern = /#{wand.split(' ').join('.*?')}/i
        "#{@world.hands.right.name}#{@world.hands.left.name}" =~ pattern ? true : false
      end
    end

    # cmd_wandolier: the wand from hand or the RESERVE list, else
    # from the container (RUB it when empty), RESERVE it, WAVE it.
    #
    # @bigshot cmd_wandolier
    class Wandolier < Base
      include CombatRt

      # Wand's WAVED plus the referent-gone line a reserved wand can draw.
      WAVED = /d100|You hurl|is already dead|You do not see that here|You are in no condition|I could not find|What were you referring to/
      # The stance words the routine line may name for the wave.
      STANCES = %w[offensive advance forward neutral guarded defensive].freeze

      # @param world [World]
      # @param target [Object] the creature (responds to `id`)
      # @param policy [Engage::Policy] `wand` list, `fresh_wand_container`, `hunting_stance`
      # @param state [Engage::State] `wand_index`, the cursor into the list
      # @param args [String] up to two words: "noreserve" and/or a STANCES word
      # @param stance [#call, nil] Engage's stance setter, given a stance name
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, target:, policy:, state:, args: '', stance: nil, **opts)
        super(world, target: target, **opts)
        @target = target
        @policy = policy
        @state = state
        @stance = stance
        tokens = args.to_s.downcase.split(/\s+/).reject(&:empty?)
        @noreserve = tokens.include?('noreserve')
        @wave_stance = (tokens & STANCES).first || 'offensive'
      end

      # @return [Symbol] :ok, or :dead, :no_container, :no_wands
      def preconditions
        return :dead if me.dead?
        return :no_container if @policy.fresh_wand_container.to_s.empty?
        return :no_wands if Array(@policy.wand).empty?

        :ok
      end

      # @return [Actions::Result] the WAVE's Result on a WAVED line; failed
      #   :wand_timeout, :no_wand (six tries), :too_injured (:too_injured_for_wands
      #   on the bus)
      def perform
        # Wand shares this cursor and only ever advances it, so an exhausted
        # list used to reach .split on nil and raise NoMethodError out of the
        # action, killing the tick rather than reporting a missing wand.
        wand_name = Array(@policy.wand)[@state.wand_index.to_i]
        if wand_name.nil?
          Events.emit(:no_fresh_wands)
          return Result.new(status: :failed, reason: :no_fresh_wands)
        end

        pattern = /#{wand_name.split(' ').join('.*?')}/i
        send_through_ladder('reserve list') if reserve.nil?
        wand = nil
        6.times do
          wand = ([@world.hands.right, @world.hands.left] + Array(reserve)).compact.find { |o| o.id && o.name.to_s =~ pattern }
          break if wand

          result = send_and_match("get #{wand_name} from my #{@policy.fresh_wand_container}", /You (?:remove|slip|slide)|Get what/, timeout: 3)
          return Result.new(status: :failed, reason: :wand_timeout) unless result.success?

          send_through_ladder("rub my #{@policy.fresh_wand_container}") if result.line =~ /Get what/
        end
        return Result.new(status: :failed, reason: :no_wand) if wand.nil?

        send_through_ladder("reserve ##{wand.id}") if !@noreserve && [@world.hands.right, @world.hands.left].any? { |h| h.id.to_s == wand.id.to_s }
        @stance&.call(@wave_stance)
        result = send_and_match("wave ##{wand.id}", WAVED, timeout: 3)
        @stance&.call(@policy.hunting_stance) if @policy.hunting_stance
        if result.success? && result.line =~ /You are in no condition/
          Events.emit(:too_injured_for_wands)
          return Result.new(status: :failed, reason: :too_injured, line: result.line)
        end
        send_through_ladder('reserve list') if result.success? && result.line =~ /What were you referring to/
        result
      end

      private

      def reserve
        ::GameObj.reserve
      rescue StandardError
        nil
      end
    end

    # cmd_unarmed: smite a noncorporeal at tier 3, mstrike unless
    # the profile forbids it, then the tier-3 attack, the advertised
    # follow-up, or the command, at the next aim part; read the answer for
    # the tier, the follow-up, a lost part, roundtime.
    #
    # @bigshot cmd_unarmed
    class Unarmed < Base
      include CombatRt

      # @param world [World]
      # @param engage [Behaviors::Engage] the fight: target, policy, state, mstrike policy
      # @param command [String] the attack word (punch, jab, grapple, kick)
      # @param manual_aim [String] a part named on the routine line, instead of the aim list
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, engage:, command:, manual_aim: '', **opts)
        super(world, target: engage.target, **opts)
        @engage = engage
        @target = engage.target
        @command = command
        @manual_aim = manual_aim.to_s
        @policy = engage.policy
        @state = engage.state
      end

      # @return [Symbol] :ok, or :dead, :muckled
      def preconditions
        return :dead if me.dead?
        return :muckled if me.muckled?

        :ok
      end

      # @return [Actions::Result] success :mstrike, :swung, :rooted (:rooted on
      #   the bus), :soothed, :target_gone; failed :refused, or the swing's
      #   own failure
      def perform
        @state.uac_aim = -1 if !@manual_aim.empty? && @state.uac_aim.to_i.zero?
        if @policy.uac_smite && @target.type.to_s.split(',').include?('noncorporeal') && @state.unarmed_tier == 3 && @world.spell[9821]&.known?
          Smite.new(@world, target: @target, state: @state, interrupt: @interrupt).call unless @state.smite_done?.include?(@target.id.to_s)
        end

        struck = false
        unless @policy.uac_mstrike
          word = @policy.tier3.to_s.empty? ? @command : @policy.tier3
          mstrike = Mstrike.new(@world, policy: @engage.mstrike_policy, target: @target, attack: word, targets_policy: @engage.targets_policy, interrupt: @interrupt).call
          struck = mstrike.success?
          sleep 0.3
        end
        return Result.new(status: :success, reason: :mstrike) if struck

        word = if @state.unarmed_tier == 3 && !@state.unarmed_followup && !@policy.tier3.to_s.empty? then @policy.tier3
               elsif @state.unarmed_followup then @state.unarmed_followup_attack
               else @command
               end
        result = swing(word)
        return result unless result.success?

        read_answer(word)
      end

      private

      def aim_part
        return @manual_aim unless @manual_aim.empty?

        Array(@policy.aim)[@state.uac_aim.to_i]
      end

      def swing(word)
        part = aim_part
        text = part.to_s.empty? ? "#{word} ##{@target.id}" : "#{word} ##{@target.id} #{part}"
        first = send_through_ladder(text)
        first.is_a?(Result) ? first : Result.new(status: :success, line: first)
      end

      # the read loop
      def read_answer(word)
        deadline = clock_now + 5
        reason = :swung
        loop do
          line = next_line
          if line.nil?
            break if clock_now > deadline || interrupted?

            sleep 0.1
            next
          end
          case line
          when /You have (decent|good|excellent) positioning/
            @state.unarmed_tier = { 'decent' => 1, 'good' => 2, 'excellent' => 3 }[Regexp.last_match(1)]
          when /.* = .* d100: .* = -?(\d+)$/
            @state.unarmed_followup = false if @state.unarmed_followup && Regexp.last_match(1).to_i > 100
          when /Strike leaves foe vulnerable to a followup (.*) attack!/
            @state.unarmed_followup = true
            @state.unarmed_followup_attack = Regexp.last_match(1)
          when /You fail to find an opening for your strike\./
            @state.uac_aim = @state.uac_aim.to_i + 1
          when /You cannot aim that high!|is already missing that!|does not have/
            @state.uac_aim = @state.uac_aim.to_i + 1
            swing(word)
          when /Roundtime:/i
            @state.uac_aim = 0
            break
          when /^Try standing up first\.$|[wW]ait \d+ sec.*|Sorry,|You can't do that while entangled in a web|You are still stunned|from here\.  Perhaps you should try throwing or shooting something at it\./
            reason = :refused
            break
          when /You don't seem to be able to move(?: your legs)? to do that\./
            Events.emit(:rooted)
            reason = :rooted
            break
          when /You are unable to muster the will to attack anything\.|Your rage causes you to use all of your skill in an all out attack!/
            s = @world.spell[1201]
            s.cast if s&.known? && s.affordable?
            reason = :soothed
            break
          when /You currently have no valid target\.  You will need to specify one\.|^It looks like somebody already did the job for you\.$|What were you referring to/
            @state.unarmed_tier = 1
            @state.unarmed_followup = false
            @state.unarmed_followup_attack = ''
            reason = :target_gone
            break
          end
          unless target_still_live?
            @state.unarmed_tier = 1
            @state.unarmed_followup = false
            reason = :target_gone
            break
          end
        end
        Result.new(status: reason == :refused ? :failed : :success, reason: reason)
      end
    end

    # perform_reaction: WEAPON <reaction> the game offered, in the
    # hunting stance, then back.
    #
    # @bigshot perform_reaction
    class Reaction < Base
      include CombatRt

      # @param world [World]
      # @param reaction [String] the WEAPON verb the game offered
      # @param stance [#call, nil] Engage's stance setter, given a stance name
      # @param hunting_stance [String, nil] the profile's hunting stance
      # @param opts [Hash] passed to Base (`interrupt:`)
      def initialize(world, reaction:, stance: nil, hunting_stance: nil, **opts)
        super(world, **opts)
        @reaction = reaction
        @stance = stance
        @hunting_stance = hunting_stance
      end

      # @return [Symbol] :ok, or :dead
      def preconditions = me.dead? ? :dead : :ok

      # @return [Actions::Result] the WEAPON command's first answer line
      def perform
        original = me.stance_text
        @stance&.call(@hunting_stance) if @hunting_stance
        result = send_and_match("weapon #{@reaction}", /.*/, timeout: 3)
        @stance&.call(original) if original
        result
      end
    end
  end
end
