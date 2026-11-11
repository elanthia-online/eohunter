# frozen_string_literal: true

module EO
  module HunterSetup
    # Which Cleanse choices this character cannot use, read from Lich's
    # Spell, CMan and Feat when setup opens, as ecleanse's own window does
    # (ecleanse unavailable). Read-only: nothing is cast or asked of the game.
    module RecoveryAbilities
      # The Stun Maneuvers rank each stunman choice needs, as the engine uses
      # them (cleanse.rb CleanseStun). ecleanse's window offered stance 1 at
      # rank 2, which the engine would never use.
      STUNMAN_RANKS = { 'use_stance1' => 3, 'use_stance2' => 4, 'use_flee' => 5, 'use_hide' => 5 }.freeze

      # Spells a choice needs, any one of them, and what to call them.
      SPELLS = {
        'cleanse_disease'      => [[113], 'Undisease (113)'],
        'cleanse_poison'       => [[114], 'Unpoison (114)'],
        'use_stunned_barkskin' => [[605], 'Barkskin (605)'],
        'use_stunned1040'      => [[1040], "Troubadour's Rally (1040)"],
        'use_709'              => [[709], 'Grasp of the Grave (709)'],
        'use_619'              => [[619], 'Mass Calm (619)'],
        'use_213'              => [[213], 'Minor Sanctuary (213)'],
        'use_1011'             => [[1011], 'Song of Peace (1011)'],
        'use_9811'             => [[9811], 'Symbol of Sleep (9811)'],
        'use_140'              => [[140], 'Wall of Force (140)'],
        'use_919'              => [[919], "Wizard's Shield (919)"],
        'use_1635'             => [[1635], 'Divine Intervention (1635)']
      }.freeze

      module_function

      # Capture once on the script thread. When Lich's readers are missing,
      # nothing is marked unusable: unknown is not the same as cannot.
      # @param spells [#[], nil] Lich's Spell catalog
      # @param cman [#known?, #[], nil] Lich's CMan
      # @param feat [#known?, nil] Lich's Feat
      # @return [Hash{String => String}] setting key => why it cannot be used
      def capture(spells: nil, cman: nil, feat: nil)
        spells ||= ::Lich::Common::Spell if defined?(::Lich::Common::Spell)
        cman ||= ::Lich::Gemstone::CMan if defined?(::Lich::Gemstone::CMan)
        feat ||= ::Lich::Gemstone::Feat if defined?(::Lich::Gemstone::Feat)
        return {} unless spells && cman && feat

        unusable(spells, cman, feat)
      rescue StandardError
        {}
      end

      # @return [Hash{String => String}]
      def unusable(spells, cman, feat)
        knows = ->(id) { spells[id]&.known? ? true : false }
        maneuver = ->(name) { cman.known?(name) ? true : false }
        dispel = [417, 1218, 119].any?(&knows)
        cleave = maneuver.call('Spell Cleave') || maneuver.call('Spell Thieve')
        escape = feat.known?('escapeartist') ? true : false
        stun = cman['Stun Maneuvers'].to_i
        out = SPELLS.to_h { |key, (ids, name)| [key, ids.any?(&knows) ? nil : "You do not know #{name}."] }
        out['use_berserk_webbed'] = out['use_berserk_stunned'] = maneuver.call('Berserk') ? nil : 'You do not know Berserk.'
        out['determination'] = knows.call('Sigil of Determination') ? nil : 'You do not know Sigil of Determination.'
        out['cleanse_grounded'] = maneuver.call('Retreat') || escape ? nil : 'Needs Retreat or Escape Artist.'
        out['cleanse_magical'] = dispel ? nil : 'Needs a dispel: 417, 1218 or 119.'
        out['dispel_magic'] = dispel || cleave ? nil : 'Needs a dispel (417, 1218 or 119), Spell Cleave or Spell Thieve.'
        out['avoid_webs'] = [209, 417, 1218, 119].any?(&knows) || escape || cleave ? nil : 'Needs 209, a dispel, Escape Artist, Spell Cleave or Spell Thieve.'
        STUNMAN_RANKS.each { |key, rank| out[key] = stun >= rank ? nil : "Needs Stun Maneuvers rank #{rank}; you have #{stun}." }
        out.compact
      end
    end
  end
end
