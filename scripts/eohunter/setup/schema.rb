# frozen_string_literal: true

module EO
  module HunterSetup
    # Presentation metadata and a read-only adapter to the installed engine's
    # policy constructors. No command, expression or script is executed here.
    class Schema
      # Canonical page identities and their native profile setting keys.
      PAGES = {
        'area'      => %w[hunting_room_id hunting_boundaries rallypoint_room_ids],
        'creatures' => %w[targets quickhunt_targets invalid_targets always_flee_from boons_ignore boons_flee track track_creature],
        'hunting'   => %w[hunting_stance wander_stance stand_stance turbo weapon_reaction loot_script priority delay_loot loot_stance sneaky_sneaky flee_count flee_message wander_wait
                          flee_clouds flee_vines flee_webs flee_voids lone_targets_only final_loot ignore_disks box_in_hand],
        'rest'      => %w[fried overkill lte_boost oom encumbered encumbrance_grace_seconds wounded_eval creeping_dread crushing_dread wot_poison confusion
                          resting_room_id return_waypoint_ids resting_commands resting_scripts after_town_rest
                          rest_till_exp rest_till_mana rest_till_spirit rest_till_percentstamina
                          fog_return custom_fog fog_optional fog_rift
                          field_rest_room_id field_rest_for town_rest_required_eval field_rest_commands field_rest_scripts
                          field_return_waypoint_ids field_rallypoint_room_ids
                          field_hunting_prep_commands field_rest_timeout_seconds],
        'recovery'  => %w[group_aid pull deader dead_man_switch depart_switch troubadours_rally],
        'combat'    => %w[ambush archery_aim aim quick_commands disable_commands
                          tier3 uac_smite uac_mstrike mstrike_stamina_cooldown mstrike_stamina_quickstrike mstrike_mob mstrike_cooldown mstrike_quickstrike],
        'equipment' => %w[hunting_right_hand hunting_left_hand hunting_aim hunting_loadout_sets hunting_loadout_rules ammo_container ammo wand
                          wand_if_oom fresh_wand_container dead_wand_container
                          combat_buffs signs bless use_wracking wracking_spirit check_favor
                          preparations hunting_prep_commands hunting_scripts],
        'team'      => %w[group_members independent_travel independent_return group_deader ma_looter final_looter never_loot random_loot quiet_followers group_fried_trigger group_strict_movement]
      }.freeze

      # Technical expressions and obsolete compatibility controls stay tucked
      # away even when they have friendly labels and descriptions.
      # Settings holding a Ruby condition the running hunt evaluates.
      RUBY_FIELDS = %w[wounded_eval town_rest_required_eval].freeze

      # Settings whose entries are creature or boon names, comma separated.
      CREATURE_LIST_KEYS = %w[targets quickhunt_targets invalid_targets always_flee_from boons_ignore boons_flee].freeze

      ADVANCED_FIELDS = %w[flee_message box_in_hand town_rest_required_eval].freeze

      # Descriptions reflect Profile and the pure Rest/Flee/Group policies. A
      # missing description deliberately exposes a raw advanced control.
      # Worked examples for the two loadout boxes, one line each, shared by
      # their tooltips and the example under the boxes so they agree.
      LOADOUT_RULES_EXAMPLE = ["- target: triton protector", "  set: slasher", "- type: undead", "  set: blunt", "- target: wight", "  type: undead", "  set: blessed"].freeze
      LOADOUT_SETS_EXAMPLE = ['slasher:', '  right: falchion', '  left: ready:shield', 'blunt:', '  right: war hammer', '  aim: head',
                              'blessed:', '  right: blessed maul', '  left: empty'].freeze

      # A non-breaking space: a tooltip may squeeze ordinary leading spaces,
      # and YAML needs its two.
      NBSP = [160].pack('U').freeze

      # An example as tooltip text: on lines of its own, indentation kept.
      # @param lines [Array<String>]
      # @return [String]
      def self.example(lines)
        "\n\nFor example:\n" + lines.map { |line| line.sub(/\A +/) { |spaces| NBSP * spaces.size } }.join("\n")
      end

      COPY = {
        'loot_script'                 => ['Loot script', 'The script that loots for you, such as eloot. Leave blank to use plain LOOT.'],
        'priority'                    => ['Priority targets', 'Switch to a creature that is earlier in your target list when one shows up. Off: finish the current target first.'],
        'delay_loot'                  => ['Delay looting', 'While creatures are still up, wait a moment between loot attempts instead of looting every kill at once.'],
        'loot_stance'                 => ['Loot in defensive', 'Go to defensive before looting while creatures are still up.'],
        'final_loot'                  => ['Final loot', 'Loot one last time before leaving a room or heading back to rest.'],
        'flee_clouds'                 => ['Flee clouds', 'Leave the room when a cloud is in it.'],
        'flee_vines'                  => ['Flee vines', 'Leave the room when vines are in it.'],
        'flee_webs'                   => ['Flee webs', 'Leave the room when webs are in it.'],
        'flee_voids'                  => ['Flee voids', 'Leave the room when a void is in it.'],
        'ignore_disks'                => ['Ignore other disks', 'Hunt a room even when someone else\'s disk is in it. Rooms with other players are still skipped.'],
        'fog_return'                  => ['Return method', 'How to get back to the rest room: walk, or a teleport you know.'],
        'fog_optional'                => ['Teleport only if needed', 'Only teleport home when hurt or encumbered. Otherwise walk.'],
        'fog_rift'                    => ['Rift escape', 'Use the Rift escape option when teleporting home.'],
        'custom_fog'                  => ['Return commands', 'Commands to send, in order, when the return method is Custom.'],
        'return_waypoint_ids'         => ['Waypoints home', 'Rooms to walk through, in order, on the way to the rest room. Comma separated.'],
        'field_return_waypoint_ids'   => ['Waypoints to field rest', 'Rooms to walk through, in order, on the way to the field rest room. Comma separated.'],
        'field_rallypoint_room_ids'   => ['Rally after field rest', 'Rooms to walk through, in order, on the way back to the hunt from field rest. Comma separated.'],
        'rallypoint_room_ids'         => ['Rally point', 'Rooms to walk through, in order, on the way to the start room. Comma separated.'],
        'boons_ignore'                => ['Boons to avoid', 'Don\'t attack a creature with any of these boons. It can still attack you.'],
        'boons_flee'                  => ['Boons to flee', 'Leave the room when a creature has any of these boons.'],
        'tier3'                       => ['Excellent positioning', 'The attack to use when unarmed combat reaches excellent positioning.'],
        'aim'                         => ['Unarmed aim order', 'Body parts to aim unarmed attacks at, in order. Comma separated.'],
        'uac_smite'                   => ['Voln SMITE', 'Use Voln SMITE in unarmed combat when it applies.'],
        'uac_mstrike'                 => ['Disable auto MSTRIKE', 'Ticked: unarmed combat never MSTRIKEs on its own. MSTRIKE in a routine still works.'],
        'mstrike_mob'                 => ['MSTRIKE at this many', 'MSTRIKE when at least this many creatures are in the room.', 'creatures'],
        'mstrike_cooldown'            => ['MSTRIKE on cooldown', 'Allow MSTRIKE while it is on cooldown, which costs extra stamina.'],
        'mstrike_quickstrike'         => ['QUICKSTRIKE with MSTRIKE', 'Add QUICKSTRIKE to MSTRIKE.'],
        'mstrike_stamina_cooldown'    => ['Stamina for cooldown MSTRIKE', 'Only MSTRIKE on cooldown with at least this much stamina. Blank: your maximum.', 'stamina'],
        'mstrike_stamina_quickstrike' => ['Stamina for QUICKSTRIKE', 'Only QUICKSTRIKE with at least this much stamina.', 'stamina'],
        'ammo'                        => ['Ammunition', 'What you fire. The hunt does not gather spent ammunition.'],
        'wand'                        => ['Wand types', 'Wands to use, by name. Comma separated.'],
        'wand_if_oom'                 => ['Wand when out of mana', 'Use a wand when you are out of mana. Low mana still sends you to rest.'],
        'fresh_wand_container'        => ['Fresh wands', 'The container your charged wands are in.'],
        'dead_wand_container'         => ['Used wands', 'The container to put empty wands in.'],
        'dead_man_switch'             => ['Log out on death', 'QUIT when you die. DEPART on death wins if both are ticked.'],
        'depart_switch'               => ['DEPART on death', 'DEPART when you die, giving up your body and any chance to be raised.'],
        'pull'                        => ['Pull players', 'Pull any player who is down while a creature is attacking. Group members are always pulled.'],
        'deader'                      => ['Stop for the dead', 'Stop hunting when any dead player is in the room.'],
        'weapon_reaction'             => ['Weapon reactions', 'Use the weapon reaction the game offers before the next attack.'],
        'troubadours_rally'           => ['Rally the group (1040)', 'Troubadour\'s Rally when you are webbed, asleep, stunned or frozen, or a group member has an ailment.'],
        'group_aid'                   => ['Group aid', 'Help a group member who has an ailment you can cure. One who is stunned, webbed or asleep comes before your own poison; their poison or disease comes after yours.'],
        'group_deader'                => ['Stop for a dead member', 'Stop hunting when a group member dies.'],
        'quiet_followers'             => ['Leader services first', 'Followers wait for the leader before starting their own rest.'],
        'never_loot'                  => ['Never loot', 'Characters who are never sent to loot. Comma separated.'],
        'field_rest_commands'         => ['Field rest commands', 'Commands to send, in order, at the field rest room.'],
        'field_rest_scripts'          => ['Field rest scripts', 'Scripts to run, in order, at the field rest room, such as eherbs.'],
        'field_hunting_prep_commands' => ['Before leaving field rest', 'Commands to send, in order, before going back to the hunt from field rest.'],
        'group_members'               => ['Required followers', 'Characters who must be with you for ;eohunter <hunt> group. Each one has to agree to follow you.'],
        'signs'                       => ['Upkeep', 'Spells and signs to keep up, by number. Comma separated.'],
        'use_wracking'                => ['Society mana recovery', 'Use Sign of Wracking, Sigil of Power or Symbol of Mana when you are low on mana.'],
        'wracking_spirit'             => ['Spirit kept for wracking', 'Don\'t use Sign of Wracking below this much spirit.', 'spirit'],
        'check_favor'                 => ['Check favor', 'Only use a Voln symbol when you have the favor for it.'],
        'bless'                       => ['Renew blessings', 'Re-bless your weapon when its blessing wears off.'],
        'hunting_stance'              => ['Attack stance', 'The stance to attack in.'],
        'wander_stance'               => ['Wander stance', 'The stance to walk and wait in.'],
        'stand_stance'                => ['Stand-up stance', 'The stance to take after standing up.'],
        'turbo'                       => ['Turbo (test)', 'Test option. Send the next commands without waiting for each reply. Stance: stance and attack together. All: target, stance and attack together. Can type ahead of the game.'],
        'archery_aim'                 => ['Ranged aim order', 'Body parts to aim FIRE at, in order, such as right eye, head, chest. Comma separated.'],
        'ambush'                      => ['Ambush aim order', 'Body parts to aim AMBUSH at, in order. Comma separated.'],
        'ammo_container'              => ['Ammunition container', 'Where to put ammunition back when a shot is refused.'],
        'sneaky_sneaky'               => ['Hide while moving', 'Hide before moving to the next room.'],
        'track'                       => ['Track', 'Rangers: TRACK the creature below once in each room before moving on, and follow its trail.'],
        'track_creature'              => ['Creature to track', 'The creature TRACK follows, as you would type it. ;eohunter <hunt> track <creature> tracks another for one run.'],
        'hunting_room_id'             => ['Start room', 'The room the hunt starts in. A room number, or a UID such as u1234.', 'room'],
        'hunting_boundaries'          => ['Boundary rooms', 'Rooms the hunt never walks into. They keep you inside the area. Comma separated.', 'rooms'],
        'targets'                     => ['Creatures to hunt', 'Creatures to attack. Add (b) to (j) after a name to use that routine. Blank: anything you can fight.'],
        'quickhunt_targets'           => ['Quick-hunt creatures', 'Creatures to fight with the Quick routine instead of the usual one.'],
        'invalid_targets'             => ['Creatures to ignore', 'Creatures never to attack. They can still attack you.'],
        'always_flee_from'            => ['Creatures to flee', 'Leave the room when any of these creatures or players is in it.'],
        'resting_room_id'             => ['Town rest room', 'The room to rest in. Needed for buffs, preparations and field rest.', 'room'],
        'fried'                       => ['Mind full', 'Go rest when your mind is at least this full. Above 100: never.', 'mind %'],
        'overkill'                    => ['Extra kills', 'Kills to make after your mind is full before going to rest.', 'kills'],
        'lte_boost'                   => ['LTE boosts', 'Long-term experience boosts to use before going to rest.', 'boosts'],
        'oom'                         => ['Low mana', 'Go rest when your mana falls below this. Below 0: never.', 'mana %'],
        'encumbered'                  => ['Encumbrance', 'Go rest when you are at least this encumbered.', 'percent'],
        'encumbrance_grace_seconds'   => ['Weight settle time', 'How long to stay that encumbered before going to rest, so looting can settle.', 'seconds'],
        'creeping_dread'              => ['Creeping Dread', 'Go rest at this many stacks of Creeping Dread. 0: never.', 'stacks'],
        'crushing_dread'              => ['Crushing Dread', 'Go rest at this many stacks of Crushing Dread. 0: never.', 'stacks'],
        'wot_poison'                  => ['Wall of Thorns poison', 'Go rest when poisoned by a Wall of Thorns.'],
        'confusion'                   => ['Confusion', 'Go rest when confused.'],
        'rest_till_exp'               => ['Rested mind', 'Rest until your mind is down to this.', 'mind %'],
        'rest_till_mana'              => ['Rested mana', 'Rest until your mana is back to this.', 'mana %'],
        'rest_till_spirit'            => ['Rested spirit', 'Rest until your spirit is back to this.', 'spirit'],
        'rest_till_percentstamina'    => ['Rested stamina', 'Rest until your stamina is back to this.', 'stamina %'],
        'resting_commands'            => ['Rest commands', 'Commands to send, in order, at the rest room. Comma separated.'],
        'resting_scripts'             => ['Rest scripts', 'Scripts to run, in order, at the rest room, such as eherbs or eloot sell. The hunt waits for each.'],
        'hunting_prep_commands'       => ['Before hunting', 'Commands to send, in order, before heading out to hunt. Comma separated.'],
        'hunting_scripts'             => ['Scripts while hunting', 'Scripts to start when the hunt begins.'],
        'field_rest_room_id'          => ['Field rest room', 'A rest room near the hunt, for solo hunts. Anything it can\'t fix still goes to town.', 'room'],
        'field_rest_for'              => ['Field rest handles', 'What to rest for at the field rest room, such as fried and mana. Anything else goes to town.'],
        'field_rest_timeout_seconds'  => ['Field rest limit', 'Go to town if field rest takes longer than this. 0: no limit.', 'seconds'],
        'after_town_rest'             => ['After town rest', 'Go back to hunting, or stop.'],
        'wounded_eval'                => ['Injury condition', 'A Ruby condition. When it is true, go rest. Test now shows what it says right now.'],
        'town_rest_required_eval'     => ['Town instead when', 'A Ruby condition. When it is true, rest in town instead of the field rest room.'],
        'hunting_commands'            => ['Combat routine', 'The usual routine: commands to attack with, in order. A creature marked (b) in Creatures to hunt uses routine b instead, and so on.'],
        'disable_commands'            => ['Fried routine', 'Commands to use once your mind is full while the group keeps hunting.'],
        'quick_commands'              => ['Quick routine', 'Commands for quick-hunt creatures.'],
        'hunting_right_hand'          => ['Right hand', 'What to hold in your right hand while hunting.'],
        'hunting_left_hand'           => ['Left hand', 'What to hold in your left hand while hunting.'],
        'hunting_aim'                 => ['Aimed body part', 'The body part to aim at while hunting. Blank: leave it as it is.'],
        'hunting_loadout_sets'        => ['Equipment sets', 'Named sets of what to hold. Each set is a name at the left edge, then any of right:, left: and aim: on lines indented exactly two spaces under it. Right and left take the same values as the Right and Left hands; aim takes a body part. Anything a set leaves out comes from Hands. A set is only used when a rule names it.' + example(LOADOUT_SETS_EXAMPLE)],
        'hunting_loadout_rules'       => ['Equipment rules', 'Which set to use for which creature. Each rule starts with a dash and needs set: (a name from Sets) plus target:, type: or both, each on its own line indented exactly two spaces to line up after the dash. target: is a creature name, matched as in Creatures to hunt. type: is living, undead or noncorporeal. With both, the creature must match both. Rules are checked top to bottom and the first match wins, so put specific rules above general ones. A creature no rule matches uses the Right and Left hands.' + example(LOADOUT_RULES_EXAMPLE)],
        'combat_buffs'                => ['Required buffs', 'Buffs you must have to hunt, and what to do when one drops. Solo hunts only.'],
        'preparations'                => ['Item preparations', 'Named commands a routine runs with prepare NAME. Solo hunts only.'],
        'flee_count'                  => ['Too many targets', 'Leave the room when there are more creatures than this.', 'creatures'],
        'lone_targets_only'           => ['Lone targets', 'Only go into a fight in a room with a single creature.'],
        'flee_message'                => ['Flee on message', 'Leave the room when the game says something matching this. A regular expression.'],
        'wander_wait'                 => ['Wait for a creature', 'How long to wait in an empty room before moving on.', 'seconds'],
        'group_fried_trigger'         => ['Whose full mind returns', 'Whose full mind sends the group to rest: any, all, or names.'],
        'group_strict_movement'       => ['Wait for members', 'Wait for every member before moving to the next room.'],
        'independent_travel'          => ['Followers travel alone', 'Followers walk to the hunt on their own instead of following the leader.'],
        'independent_return'          => ['Followers return alone', 'Followers walk back to rest on their own.'],
        'final_looter'                => ['Final looter', 'Who does the group\'s final loot before it leaves a room. Blank: the team looter.'],
        'ma_looter'                   => ['Team looter', 'Who loots the group\'s kills.'],
        'random_loot'                 => ['Least encumbered loots', 'Whoever is carrying least does the looting.'],
        'box_in_hand'                 => ['Box in hand', 'Not used.']
      }.freeze

      # Presentation choices for existing native values, not new execution policy.
      OPTIONS = {
        'fog_return'      => [
          [0, 'Walk'], [1, 'Spirit Guide (130)'], [2, 'Symbol of Return'],
          [3, "Traveler\'s Song (1020)"], [4, 'Sigil of Escape'],
          [5, 'Familiar Gate (930)'], [6, 'Custom return commands']
        ],
        'tier3'           => %w[jab punch grapple kick].map { |word| [word, word.capitalize] },
        'after_town_rest' => [['resume', 'Resume hunting'], ['stop', 'Finish after town recovery']],
        'turbo'           => [['off', 'Off'], ['stance', 'Stance'], ['all', 'All']],
        # Lich's CreatureInstance::BODY_PARTS, spaced as AIM takes them, without
        # nerves, which is a wound and not somewhere to aim.
        'hunting_aim'     => %w[head neck chest abdomen back left\ eye right\ eye left\ arm right\ arm left\ hand right\ hand
                                left\ leg right\ leg left\ foot right\ foot].map { |part| [part, part.capitalize] }
      }.freeze

      # Saved values a choice shows as one of its options: Bigshot wrote
      # turbo as true or false.
      ALIASES = { 'turbo' => { 'true' => 'all', 'false' => 'off' } }.freeze

      # Value types for native cleaners; other cleaners hold text.
      TYPES = { bool: 'boolean', to_i: 'integer', to_f: 'number', seconds: 'number', structured: 'structured' }.freeze
      # Pure native policy constructors checked without any game context.
      POLICIES = %i[rest_policy flee_policy wander_policy loot_policy loadout_policy loadout_selection maintain_policy
                    survival_policy group_policy engage_policy mstrike_policy buff_policy].freeze

      # Bind metadata and validation to the installed native policy classes.
      # @param profile_class [Class] the installed EO::Engine::Profile
      # @param cleanse_policy_class [Class, nil] the installed Cleanse::Policy
      def initialize(profile_class:, cleanse_policy_class: nil)
        @profile_class = profile_class
        @cleanse_policy_class = cleanse_policy_class
      end

      # Every native rule has exactly one canonical location. Unknown future
      # rules receive an explicitly raw editor instead of inferred behavior.
      # @return [Array<Hash{String => Object}>] JSON-ready field descriptions
      def fields
        @profile_class::RULES.reject { |key, _rule| key == 'recovery' }.map do |key, (cleaner, default)|
          copy = COPY[key]
          page = PAGES.find { |_name, keys| keys.include?(key) }&.first
          page = 'combat' if key.match?(/\Ahunting_commands(?:_[b-j])?\z/)
          aliases = [key]
          aliases += %w[fried full mind] if key == 'disable_commands'
          aliases += %w[tail head follower group multi-account] if page == 'team'
          {
            'key' => key, 'type' => TYPES.fetch(cleaner, 'string'), 'cleaner' => cleaner.to_s,
            'options' => field_options(key, cleaner),
            'default' => copy_value(default), 'label' => copy ? copy[0] : key.split('_').map(&:capitalize).join(' '),
            'help' => copy ? copy[1] : routine_help(key),
            'page' => page || 'hunting', 'aliases' => aliases, 'editor' => copy && cleaner != :structured ? 'guided' : 'raw',
            'advanced' => ADVANCED_FIELDS.include?(key) || copy.nil? || cleaner == :structured,
            'units' => copy && copy[2], 'scope' => 'hunt or inherited character default'
          }
        end + [recovery_field]
      end

      # Find canonical controls by matching every search term in their metadata.
      # @param query [String] label, native key or familiar legacy term
      # @return [Array<Hash{String => Object}>] canonical matching fields
      def search(query)
        terms = query.to_s.downcase.split
        fields.select do |field|
          text = [field['key'], field['label'], field['help'], field['units'], *field['aliases']].join(' ').downcase
          terms.all? { |term| text.include?(term) }
        end
      end

      # Describe supported contexts without promising unavailable recovery modes.
      # @return [Hash{String => Object}] baseline capability restrictions
      def capabilities
        {
          'field_rest' => 'ordinary solo hunts only', 'combat_buffs' => 'ordinary solo hunts only',
          'repeat_until_target_gone' => defined?(::EO::Engine::Engage::Routine::REPEAT_UNTIL_TARGET_GONE) ? true : false,
          'injury_checks' => %w[able_to_cast? able_to_use_ranged? able_to_sneak? get_injury_data].to_h do |method|
            [method, defined?(::Lich::Gemstone::Injured) && ::Lich::Gemstone::Injured.respond_to?(method) ? true : false]
          end,
          'preparations' => 'ordinary solo hunts only', 'configurable_dispel_recovery' => false,
          'dispel_recovery_note' => 'Immediate/post-combat rebuff strategies and bulk thresholds require a separate engine feature.',
          'group_note' => 'A physical party does not enroll other players in coordinated automation. Setup does not start their scripts.'
        }
      end

      # Use the installed dispatch vocabulary, not a separate technique list.
      # This does not query a character's skills or claim they are learned.
      # @return [Array<Hash{Symbol => String}>] native words and display names
      def routine_maneuvers
        return [] unless defined?(::EO::Engine::Actions::Maneuver::WORDS)

        ::EO::Engine::Actions::Maneuver::WORDS.map do |word, (category, name)|
          { word: word, category: category.to_s, name: name }
        end.sort_by { |entry| [entry[:category], entry[:name]] }
      end

      # What each boon does, in a line, from the wiki's boss creature page:
      # https://gswiki.play.net/Category:Boss_creatures (read 2026-11-07).
      # The page says its notes may be inaccurate; these are its words
      # shortened, not ours. Keyed by the target reader's ability names.
      BOON_EFFECTS = {
        'crit_death_immune'  => 'Immune to critical death, like constructs and golems.',
        'crit_padding'       => 'Reduces critical hits against it.',
        'crit_weighting'     => 'Its hits crit harder.',
        'damage_padding'     => 'Absorbs magic attacks, negating their damage.',
        'dmg_weighting'      => 'Its hits do more damage.',
        'diseased'           => 'Inflicts disease.',
        'dispelling'         => 'Casts Spirit Dispel and Elemental Dispel; may flare a dispel before attacking.',
        'elem_flares'        => 'Elemental flares on its attacks.',
        'elemental_negation' => 'Absorbs elemental magic attacks, negating their damage.',
        'extra_elem'         => 'Casts additional elemental spells.',
        'extra_spirit'       => 'Casts additional spiritual spells.',
        'extra_other'        => 'Casts additional spells of other kinds.',
        'ethereal'           => 'Non-corporeal undead; no Sheer Fear.',
        'frenzy'             => 'More aggressive.',
        'jack'               => 'Jack of all trades.',
        'magic_resistance'   => 'Takes half damage from spells.',
        'mind_blast'         => 'A mental stun spell, with a short protection window after.',
        'parting_shot'       => 'Attacks its killer once more on death, unless stunned, webbed or immobilized.',
        'physical_negation'  => 'A random physical damage shield, likelier against repeated attacks of one kind.',
        'poisonous'          => 'Releases a poison gas cloud; Purify Air counters it.',
        'regen'              => 'Heals over time, like Troll\'s Blood; fire does not stop it.',
        'soul'               => 'Soul stealing: may carry Foresight, Mantle of Faith or Spirit Guard.',
        'stun_immune'        => 'Immune to stuns.',
        'terrifying'         => 'A check before each attack that can push the attacker into a defensive stance.',
        'weaken'             => 'Weaken.'
      }.freeze

      # Boons recognized by the installed target reader, each with the
      # ASSESS words that reveal it and what it does. Unknown imported names
      # remain editable separately; no wiki-only ability is advertised here.
      # @return [Array<Hash{Symbol => Object}>] key, label, adjectives, effect
      def boon_abilities
        return [] unless defined?(::EO::Engine::Targets::BOON_ADJECTIVES)

        ::EO::Engine::Targets::BOON_ADJECTIVES.map do |key, adjectives|
          { key: key, label: key.split('_').map(&:capitalize).join(' '), adjectives: adjectives.dup,
            effect: BOON_EFFECTS.fetch(key, '') }
        end
      end

      # Bare native buff checks with ordinary present/absent semantics.
      # @return [Array<String>] installed buff-condition words
      def routine_buff_conditions
        return [] unless defined?(::EO::Engine::Engage::Conditions::BUFF_WORDS)

        ::EO::Engine::Engage::Conditions::BUFF_WORDS.keys.dup
      end

      # Validate through native constructors, without runtime contexts or eval.
      # Missing geometry is distinct from malformed configuration so drafts
      # remain saveable. Ready means configuration-ready, not combat-safe.
      # @param raw [Hash{String => Object}] effective raw settings
      # @param uid_ids [#call, nil] read-only UID resolver
      # @param mode [String, nil] native head/tail mode, or solo
      # @param controlled [Boolean] LAB owns the hunt
      # @param bounty [Boolean] ebounty owns the hunt
      # @return [Hash{String => Object}] errors, missing data and warnings
      def validate(raw, uid_ids: nil, mode: nil, controlled: false, bounty: false)
        result = { 'valid' => false, 'ready' => false, 'errors' => [], 'missing' => [], 'warnings' => [], 'normalized' => {} }
        unless raw.is_a?(Hash)
          result['errors'] << issue(nil, 'Profile settings must be a mapping.')
          return result
        end
        profile = @profile_class.new(copy_value(raw), uid_ids: uid_ids)
        result['normalized'] = json_value(profile.settings)
        unless capabilities['repeat_until_target_gone']
          profile.settings.each do |key, value|
            next unless key.match?(/\Ahunting_commands(?:_[b-j])?\z/) || %w[quick_commands disable_commands].include?(key)
            next unless ::EO::Engine::Engage::Routine.parse(value).any? { |line| line.modifiers.any? { |mod| mod.casecmp?('untildead') } }

            result['errors'] << issue(key, 'This engine does not support untildead. Upgrade Hunter and setup together before using repeat-on-target.')
          end
        end
        POLICIES.each { |method| profile.public_send(method) }
        profile.targets_policy.matchers # Native regex compilation is lazy.
        profile.validate_rest_mode!(mode, controlled: controlled, bounty: bounty)
        validate_recovery(raw, result)
        validate_geometry(raw, profile, result, uid_ids)
        %w[hunting_stance wander_stance stand_stance].each do |key|
          next if raw[key].to_s.strip.empty? || raw[key].to_s.strip.downcase == profile[key]
          result['warnings'] << issue(key, "The native engine replaces this stance with #{profile[key].inspect}.", 'normalized')
        end
        if !raw['flee_message'].to_s.strip.empty? && profile['flee_message'].nil?
          result['warnings'] << issue('flee_message', 'The native engine ignores this invalid message pattern.', 'normalized')
        end
        RUBY_FIELDS.each do |key|
          next if raw[key].to_s.strip.empty?

          problem = ruby_syntax_error(raw[key].to_s)
          if problem
            result['errors'] << issue(key, "Not valid Ruby: #{problem}")
          else
            result['warnings'] << issue(key, 'Custom Ruby: the syntax is valid, but what it decides during a hunt is not checked.', 'not_checked')
          end
        end
        unknown = raw.keys.map(&:to_s) - @profile_class::RULES.keys - ['recovery']
        unknown.each { |key| result['warnings'] << issue(key, 'Unknown extension setting preserved; its behavior is not checked.', 'not_checked') }
        result['valid'] = result['errors'].empty?
        result['ready'] = result['valid'] && result['missing'].empty?
        result
      rescue ArgumentError, TypeError, RegexpError => e
        key = (@profile_class::RULES.keys + ['recovery']).find { |candidate| e.message.include?(candidate) }
        result['errors'] << issue(key, e.message)
        result
      end

      # Check reusable character settings through the same native constructors.
      # Profile requires a rest destination while constructing enabled buff and
      # preparation policies. An omitted destination receives a temporary positive
      # ID solely for structural checking; it is never saved or returned. Every
      # composed hunt must pass #validate with its actual destinations and mode.
      # @param raw [Hash{String => Object}] reusable character settings
      # @param uid_ids [#call, nil] read-only UID resolver
      # @return [Hash{String => Object}] structural validity; ready is always false
      def validate_defaults(raw, uid_ids: nil)
        return validate(raw, uid_ids: uid_ids) unless raw.is_a?(Hash)

        context = copy_value(raw)
        temporary_rest = context['resting_room_id'].to_s.strip.empty?
        context['resting_room_id'] = 1 if temporary_rest
        result = validate(context, uid_ids: uid_ids)
        result['ready'] = false
        result['normalized'].select! { |key, _value| raw.key?(key) }
        result['normalized'].delete('resting_room_id') if temporary_rest
        result['missing'].each do |missing|
          result['warnings'] << missing.merge('kind' => 'context_required')
        end
        result['missing'] = []
        result['warnings'] << issue(nil, 'Character defaults are structurally checked only. Each composed hunt must supply its own mapped hunt and rest rooms and pass native capability validation before launch.', 'context_required')
        result
      end

      private

      def field_options(key, cleaner)
        return @profile_class::STANCES + (0..100).step(10).map(&:to_s) if cleaner == :stance

        OPTIONS[key]&.map { |value, label| { 'value' => value.to_s, 'label' => label } }
      end

      # The hunt's Cleanse preferences as the Recovery page draws them, in
      # ecleanse's own words. troubadours_rally has its own field.
      RECOVERY_CONTROLS = [
        ['Afflictions', [
          ['cleanse_magical', 'Cleanse magical', 'Confusion, vertigo, sounds or Thought Lash, with 417, 119 or 1218 if known.'],
          ['cleanse_grounded', 'Cleanse grounded', 'Clear rooted or pressed.'],
          ['cleanse_poison', 'Cure poison', 'Unpoison (114).'],
          ['cleanse_disease', 'Cure disease', 'Undisease (113).'],
          ['determination', 'Sigil of Determination', nil],
          ['itchy_curse', 'Manage itchy curse', 'Run to the safe room below with the itchy curse.'],
          :safe_room
        ]],
        ['Hazards', [
          ['dispel_magic', 'Dispel magic', nil],
          ['avoid_webs', 'Dispel webs', nil],
          ['use_berserk_webbed', 'Berserk when webbed', nil],
          ['hive_traps_apparatus', 'Disarm hive apparatus', nil],
          ['hive_traps_ground', 'Disarm hive ground', nil],
          ['break_runestone', 'Break runestone', 'Attacks pale hovering runestones (Onslaught).']
        ]],
        # The spells here are not for a stun: they quiet the room before the
        # weapon is searched for, then cover the search (cleanse.rb
        # CleanseSettleRoom, cast_213_1011).
        ['Disarmed', [
          ['recover_disarmed', 'Recover disarmed weapons', 'Uses 218 if active.'],
          'Calm the room first, the first that works',
          ['use_140', 'Wall of Force (140)', nil],
          ['use_619', 'Mass Calm (619)', nil],
          ['use_709', 'Grasp of the Grave (709)', 'Not against appendages.'],
          ['use_919', "Wizard's Shield (919)", nil],
          ['use_9811', 'Symbol of Sleep (9811)', nil],
          'While searching',
          ['use_213', 'Minor Sanctuary (213)', nil],
          ['use_1011', 'Song of Peace (1011)', nil]
        ]],
        ['When stunned', [
          ['use_stunned_barkskin', 'Barkskin (605)', nil],
          ['use_berserk_stunned', 'Berserk', nil],
          ['use_stunned1040', 'Shout 1040', "Troubadour's Rally, to break your own stun."],
          ['use_1635', 'Divine Intervention (1635)', nil],
          'Stunman, one of',
          ['use_stance1', 'Stance 1', 'Only one stunman choice can be on.'],
          ['use_stance2', 'Stance 2', 'Only one stunman choice can be on.'],
          ['use_flee', 'Flee', 'Only one stunman choice can be on.'],
          ['use_hide', 'Hide', 'Only one stunman choice can be on.']
        ]]
      ].freeze

      # ecleanse's window allows one of these at a time.
      RECOVERY_EXCLUSIVE = %w[use_stance1 use_stance2 use_flee use_hide].freeze

      # What a lettered routine is for, or '' for any other setting.
      def routine_help(key)
        letter = key[/\Ahunting_commands_([b-j])\z/, 1]
        letter ? "Commands for creatures marked (#{letter}) in Creatures to hunt." : ''
      end

      def recovery_field
        {
          'key' => 'recovery', 'type' => 'structured', 'cleaner' => 'structured', 'default' => {},
          'label' => 'Integrated recovery preferences', 'page' => 'recovery', 'editor' => 'raw', 'units' => nil,
          'scope' => 'hunt or inherited character default', 'aliases' => %w[recovery ecleanse cleanse dispel poison disease disarm stun stunman webs hive runestone curse],
          'help' => 'What Cleanse does on this hunt. Anything not ticked is off. Standalone ecleanse and its file are not read or changed, except by Import from ecleanse.',
          'keys' => @cleanse_policy_class ? @cleanse_policy_class.members.map(&:to_s) : []
        }
      end

      def validate_recovery(raw, result)
        return unless raw.key?('recovery')
        recovery = raw['recovery']
        unless recovery.is_a?(Hash)
          result['errors'] << issue('recovery', 'Recovery preferences must be a mapping.')
          return
        end
        unless @cleanse_policy_class
          result['warnings'] << issue('recovery', 'Cleanse policy is unavailable; recovery settings have not been checked.', 'not_checked')
          return
        end
        @cleanse_policy_class.new(**recovery.to_h { |key, value| [key.to_sym, value] })
        unknown = recovery.keys.map(&:to_s) - @cleanse_policy_class.members.map(&:to_s)
        unknown.each { |key| result['warnings'] << issue("recovery.#{key}", 'Unknown recovery preference preserved; the installed Cleanse policy ignores it.', 'not_checked') }
      end

      def validate_geometry(raw, profile, result, uid_ids)
        %w[hunting_room_id resting_room_id].each do |key|
          value = profile[key]
          next if value.is_a?(Integer) && value.positive?
          result['missing'] << issue(key, 'Choose a positive mapped room ID or a resolvable room UID.', 'missing')
        end
        @profile_class::RULES.each do |key, (cleaner, _default)|
          next unless %i[rooms strict_rooms].include?(cleaner)
          raw[key].to_s.split(/,\s*/).each do |entry|
            entry = entry.strip
            next if entry.empty?
            valid = entry.match?(/\A\d+\z/) && entry.to_i.positive?
            if entry.match?(/\Au\d+\z/i)
              resolved = uid_ids&.call(entry[1..].to_i)&.first
              valid = resolved.is_a?(Integer) && resolved.positive?
            end
            result['missing'] << issue(key, "Room #{entry.inspect} could not be resolved to a positive room ID.", 'missing') unless valid
          end
        end
      end

      # Why a custom Ruby condition does not parse, without running it.
      #
      # Parsing only: nothing is evaluated, so the game and the character are
      # not touched. Prism ships with Ruby 3.3 and later; without it the check
      # is skipped rather than guessed at.
      #
      # @param source [String] the condition as written
      # @return [String, nil] the first parse error, or nil when it parses
      def ruby_syntax_error(source)
        require 'prism'
        error = Prism.parse(source).errors.first
        error && "#{error.message} (line #{error.location.start_line})"
      rescue LoadError
        nil
      end

      def issue(key, message, kind = 'invalid')
        { 'key' => key, 'message' => message, 'kind' => kind }
      end

      def copy_value(value)
        case value
        when Hash then value.to_h { |key, item| [key, copy_value(item)] }
        when Array then value.map { |item| copy_value(item) }
        when String then value.dup
        else value
        end
      end

      def json_value(value)
        case value
        when Regexp then value.source
        when Hash then value.to_h { |key, item| [key.to_s, json_value(item)] }
        when Array then value.map { |item| json_value(item) }
        else value
        end
      end
    end
  end
end
