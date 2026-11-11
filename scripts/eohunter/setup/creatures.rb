# frozen_string_literal: true

module EO
  module HunterSetup
    # Finding something to hunt, from the installed creature templates.
    #
    # A player arrives knowing their level and how they fight, not which
    # habitat they want: "I am 100 and I put things to sleep" is the question,
    # and the area follows from the answer. So the search is over creatures
    # and the areas are derived, rather than the other way round.
    #
    # The templates carry far more than this uses -- per-circle TDs, AS by
    # attack type, immunities, treasure, the creature's own messaging -- and
    # what is offered here is only what a player chooses a hunt on.
    module Creatures
      module_function

      # Fields populated for nearly every creature, and so safe to filter
      # hard on: a creature missing one is a gap in the catalogue rather than
      # a meaningful answer.
      #
      # Measured across the installed templates: level 95%, family 98%,
      # type 96%, areas 96%, boon-capable 91%.
      RELIABLE = %i[level family type undead boss bcs].freeze

      # Fields catalogued for only some creatures, where nil means NOBODY HAS
      # CHECKED rather than "no".
      #
      # sleepable is known for 45% of creatures, limbs 52%, blood 74%. A
      # filter that treated nil as false would quietly hide half the game --
      # every creature of the Elemental Confluence has sleepable, blood and
      # witherable unrecorded, so a level-95 sleep hunter asking for sleepable
      # creatures would be shown none of them and told nothing about it.
      #
      # So these are three-state, and unknown is kept unless it is excluded on
      # purpose.
      SPARSE = %i[sleepable witherable sympathy muggable blood bones limbs].freeze

      # What each sparse trait is called on an installed CreatureTemplate.
      #
      # They are predicates, and three of them carry a `has_` prefix
      # (creature.rb:237-286). Asking for a bare `sleepable` finds no method
      # and reads nil, so every creature counted as uncatalogued and all seven
      # filters reported the whole band as unknown -- a wrong answer that
      # looked exactly like the right one, since nil IS the unknown value.
      TRAIT_READERS = {
        sleepable: :sleepable?, witherable: :witherable?, sympathy: :sympathy?,
        muggable: :muggable?, blood: :has_blood?, bones: :has_bones?, limbs: :has_limbs?
      }.freeze

      # How far either side of the character's own level to look, before the
      # player says otherwise. Downward is narrower than upward because the
      # question is usually "what can I take on", not "what can I farm".
      LEVEL_BELOW = 10
      LEVEL_ABOVE = 15

      # The level range to open with.
      # @param level [Integer, nil] the character's level
      # @return [Hash] {low:, high:}
      def default_range(level)
        here = level.to_i
        return { low: 1, high: 100 } unless here.positive?

        { low: [here - LEVEL_BELOW, 1].max, high: here + LEVEL_ABOVE }
      end

      # One creature, flattened to what a player chooses on.
      #
      # @param template [#name] an installed CreatureTemplate
      # @return [Hash]
      def describe(template)
        {
          name: value(template, :name).to_s,
          level: value(template, :level),
          family: value(template, :family).to_s,
          type: value(template, :type).to_s,
          undead: value(template, :undead) == true,
          boss: value(template, :boss) == true,
          bcs: value(template, :bcs) == true,
          max_hp: value(template, :max_hp),
          otherclass: Array(value(template, :otherclass)).map { |entry| class_name(entry) }.reject(&:empty?).uniq,
          areas: Array(value(template, :areas)).filter_map { |area| area_name(area) }.uniq,
          # Kept as written: nil is "not catalogued", and flattening it to
          # false is the whole trap SPARSE exists to describe.
          traits: SPARSE.to_h { |trait| [trait, trait_value(template, trait)] }
        }
      end

      # A classification as one spelling. The templates write the same
      # class several ways -- "Non-corporeal undead", "Non Corporeal undead"
      # -- and a filter that offered both would split one class in two.
      # @param text [String] as the template wrote it
      # @return [String] lower case, hyphens and runs of space as one space
      def class_name(text)
        words = text.to_s.downcase.gsub(/[-_[:space:]]+/, ' ').strip
        words.empty? ? '' : words[0].upcase + words[1..]
      end

      # A creature's details as lines for the details popup, each
      # [style, text] with style :head or :line, after Bigshot Profiles'
      # detail panel. Anything the template does not record is left out.
      # @param template [Object] a creature template
      # @return [Array<Array(Symbol, String)>]
      def details(template)
        out = []
        line = lambda do |label, raw|
          shown = shown(raw)
          out << [:line, "#{label}: #{shown}"] if shown
        end
        kind = %i[family type size].filter_map { |field| shown(value(template, field)) }.join(' ')
        kind += ', undead' if value(template, :undead) == true
        kind += ", #{value(template, :boss_type) || 'boss'}" if value(template, :boss) == true
        out << [:line, kind] unless kind.empty?
        line.call('Max HP', value(template, :max_hp))
        line.call('Speed', value(template, :speed))
        line.call('Boon-capable', value(template, :bcs)) unless value(template, :bcs).nil?
        line.call('Wiki', value(template, :url))

        if (attack = value(template, :attack_attributes))
          out << [:head, 'Attacks']
          line.call('Physical', named(value(attack, :physical_attacks), :as))
          line.call('Bolts', named(value(attack, :bolt_spells), :as))
          line.call('Warding', named(value(attack, :warding_spells), :cs))
          line.call('Offensive spells', named(value(attack, :offensive_spells), :cs))
          line.call('Maneuvers', named(value(attack, :maneuvers), :as))
          line.call('Special', Array(value(attack, :special_abilities)).map do |ability|
            note = value(ability, :note).to_s
            note.empty? ? value(ability, :name).to_s : "#{value(ability, :name)} (#{note})"
          end)
        end

        if (defense = value(template, :defense_attributes))
          out << [:head, 'Defense']
          line.call('Armor', value(defense, :asg))
          line.call('DS', { 'melee' => :melee, 'ranged' => :ranged, 'bolt' => :bolt, 'UDF' => :udf }.filter_map do |label, field|
            found = shown(value(defense, field))
            "#{label} #{found}" if found
          end)
          line.call('TD', TD_FIELDS.filter_map do |label, field|
            found = shown(value(defense, field))
            "#{label} #{found}" if found
          end)
          line.call('Immunities', value(defense, :immunities))
          line.call('Defensive spells', named(value(defense, :defensive_spells), :ds))
          line.call('Defensive abilities', named(value(defense, :defensive_abilities), :note))
          line.call('Special defenses', named(value(defense, :special_defenses), :note))
        end

        treasure = value(template, :treasure)
        treasure = treasure.to_h if treasure.respond_to?(:to_h)
        if treasure.is_a?(Hash) && !treasure.empty?
          out << [:head, 'Treasure']
          drops = %i[coins gems boxes].select { |field| treasure[field] }.map(&:to_s)
          drops << 'skin' if treasure[:skin]
          drops << 'magic items' if treasure[:magic_items]
          line.call('Drops', drops)
          line.call('Skin', treasure[:skin]) if treasure[:skin].is_a?(String)
          line.call('Other', treasure[:other])
          line.call('Armaments', treasure[:armaments])
          line.call('Transmogs', treasure[:transmogs])
          line.call('Blunt required', true) if treasure[:blunt_required]
        end

        info = value(template, :messaging)
        info = info.instance_variable_get(:@info) if info && !info.is_a?(Hash)
        if info.is_a?(Hash)
          general = Array(info[:general]).map(&:to_s).reject(&:empty?)
          tips = (info[:class_tips] || {}).select { |_, list| Array(list).any? { |tip| !tip.to_s.empty? } }
          unless general.empty? && tips.empty?
            out << [:head, 'Tips']
            general.each { |tip| out << [:line, tip] }
            tips.each do |profession, list|
              out << [:line, "#{profession.to_s.capitalize}:"]
              Array(list).each { |tip| out << [:line, "  #{tip}"] }
            end
          end
        end
        out
      end

      # Target defense by spell circle, as the templates name them.
      TD_FIELDS = { 'Bard' => :bar_td, 'Cleric' => :cle_td, 'Empath' => :emp_td, 'Paladin' => :pal_td,
                    'Ranger' => :ran_td, 'Sorcerer' => :sor_td, 'Wizard' => :wiz_td, 'Maj Elem' => :mje_td,
                    'Min Elem' => :mne_td, 'Maj Spirit' => :mjs_td, 'Min Spirit' => :mns_td, 'Min Mental' => :mnm_td }.freeze

      # A template value as text, or nil for nothing worth a line.
      # @return [String, nil]
      def shown(raw)
        case raw
        when nil, '' then nil
        when true then 'yes'
        when false then 'no'
        when Range then "#{raw.first}-#{raw.last}"
        when Array
          parts = raw.filter_map { |item| shown(item) }
          parts.empty? ? nil : parts.join(', ')
        when Hash then raw.map { |key, item| "#{key}: #{shown(item)}" }.join(', ')
        else raw.to_s
        end
      end

      # Named entries with one figure each, as "name (figure)".
      # @return [Array<String>]
      def named(items, field)
        Array(items).filter_map do |item|
          next shown(item) unless item.is_a?(Hash)

          figure = shown(item[field])
          figure ? "#{item[:name]} (#{figure})" : item[:name].to_s
        end
      end

      # Every creature, described.
      # @param templates [Enumerable]
      # @return [Array<Hash>]
      def catalogue(templates)
        Array(templates).filter_map do |template|
          entry = describe(template)
          entry unless entry[:name].empty?
        end.sort_by { |entry| [entry[:level] || 0, entry[:name]] }
      end

      # The creatures matching a search.
      #
      # @param entries [Array<Hash>] from catalogue
      # @param query [Hash] any of:
      #   low, high      -- level range, inclusive; nil for open
      #   name           -- substring, case-insensitive
      #   families, types, classes -- lists; empty means any
      #   undead, boss, bcs        -- true/false; nil means either
      #   traits         -- {trait => true/false}, matching SPARSE keys
      #   unknown_traits -- false to exclude creatures whose trait is nil
      # @return [Array<Hash>]
      def search(entries, query = {})
        Array(entries).select { |entry| matches?(entry, query) }
      end

      # @return [Boolean]
      def matches?(entry, query)
        return false unless within_level?(entry, query)
        return false unless named?(entry, query[:name])
        return false unless listed?(entry[:family], query[:families])
        return false unless listed?(entry[:type], query[:types])
        return false unless overlaps?(entry[:otherclass], query[:classes])
        return false unless flagged?(entry, query)

        traited?(entry, query)
      end

      # How many of these creatures have a trait recorded either way.
      #
      # Shown beside a sparse filter so a player can tell "none are sleepable"
      # from "nobody has checked". Without it an empty result is
      # indistinguishable from an uncatalogued one.
      #
      # @param entries [Array<Hash>]
      # @param trait [Symbol]
      # @return [Hash] {yes:, no:, unknown:}
      def trait_tally(entries, trait)
        tally = { yes: 0, no: 0, unknown: 0 }
        Array(entries).each do |entry|
          case entry[:traits][trait]
          when true then tally[:yes] += 1
          when false then tally[:no] += 1
          else tally[:unknown] += 1
          end
        end
        tally
      end

      # The values a filter can offer, from the creatures themselves rather
      # than a list written here: a family added to Lich shows up by itself.
      # @param entries [Array<Hash>]
      # @param field [Symbol] :family, :type
      # @return [Array<String>]
      def values_for(entries, field)
        Array(entries).map { |entry| entry[field].to_s }.reject(&:empty?).uniq.sort
      end

      # Every otherclass any of these creatures carries.
      # @return [Array<String>]
      def classes_for(entries)
        Array(entries).flat_map { |entry| entry[:otherclass] }.reject(&:empty?).uniq.sort
      end

      # The areas these creatures live in, with how many of them are in each.
      #
      # This is the step from "what do I want to fight" to "where do I go":
      # having chosen creatures, the areas holding the most of them are the
      # hunts worth looking at.
      # @param entries [Array<Hash>]
      # @return [Array<Hash>] {name:, creatures:} commonest first
      def areas_for(entries)
        tally = Hash.new { |hash, key| hash[key] = [] }
        Array(entries).each do |entry|
          entry[:areas].each { |area| tally[area] << entry[:name] }
        end
        tally.map { |name, names| { name: name, creatures: names.uniq.sort } }
             .sort_by { |area| [-area[:creatures].size, area[:name]] }
      end

      # @api private
      def within_level?(entry, query)
        level = entry[:level]
        low = query[:low]
        high = query[:high]
        # A creature with no level recorded (5% of them) cannot be placed in
        # a band, so a band hides it, and says so beside the list. It is
        # still found by name: hiding it from a search for it would be the
        # same mistake as treating an unknown trait as a no.
        return !query[:name].to_s.strip.empty? if level.nil?

        return false if low && level < low.to_i
        return false if high && level > high.to_i

        true
      end

      # @api private
      def named?(entry, text)
        wanted = text.to_s.strip.downcase
        return true if wanted.empty?

        entry[:name].downcase.include?(wanted)
      end

      # @api private
      def listed?(value, wanted)
        list = Array(wanted).map(&:to_s).reject(&:empty?)
        list.empty? || list.include?(value.to_s)
      end

      # @api private
      def overlaps?(values, wanted)
        list = Array(wanted).map(&:to_s).reject(&:empty?)
        list.empty? || (Array(values).map(&:to_s) & list).any?
      end

      # @api private
      def flagged?(entry, query)
        %i[undead boss bcs].all? do |flag|
          wanted = query[flag]
          wanted.nil? || entry[flag] == wanted
        end
      end

      # @api private
      def traited?(entry, query)
        wanted = query[:traits] || {}
        keep_unknown = query[:unknown_traits] != false
        wanted.all? do |trait, want|
          next true if want.nil?

          held = entry[:traits][trait.to_sym]
          next keep_unknown if held.nil?

          held == want
        end
      end

      # @api private
      def area_name(area)
        name = area.is_a?(Hash) ? (area[:name] || area['name']) : area
        text = name.to_s
        text.empty? ? nil : text
      end

      # A sparse trait, however the template spells it.
      #
      # A Hash carries the plain key (that is how the data files are written);
      # a CreatureTemplate answers the predicate.
      # @api private
      def trait_value(template, trait)
        return template[trait] if template.is_a?(Hash)

        reader = TRAIT_READERS.fetch(trait, trait)
        return template.send(reader) if template.respond_to?(reader)

        value(template, trait)
      rescue StandardError
        nil
      end

      # @api private
      def value(template, field)
        return template[field] if template.is_a?(Hash)

        template.respond_to?(field) ? template.send(field) : nil
      rescue StandardError
        nil
      end
    end
  end
end
