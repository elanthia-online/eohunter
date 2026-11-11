# frozen_string_literal: true

module EO
  module HunterSetup
    # Native script adapter: loads policy definitions, snapshots read-only game
    # data, and builds the editor's App without starting or altering a hunt.
    module Runtime
      # Setup's own modules, in dependency order; shared readers load first.
      SETUP_PARTS = %w[
        store composition schema society_abilities area_catalog_data
        area_catalog area_zones creatures places geography hazards app equipment editor form routine_check page session launch
      ].freeze

      # The engine part list, read out of engine.rb without executing it.
      #
      # engine.rb ends in a bare `EO::Engine.load_parts`, so requiring it to
      # reach PARTS would reload every policy under a running hunt. Scraping
      # the literal keeps one authoritative list -- a part added to the engine
      # is picked up here -- without that side effect.
      PARTS_PATTERN = /PARTS\s*=\s*%w\[(.*?)\]/m

      module_function

      # Policy classes the editor reads metadata from. Loading these files
      # defines classes only.
      # @param script_dir [String] Lich script directory
      # @return [Array<String>] the part names loaded
      def profile_parts(script_dir)
        source = File.read(File.join(script_dir, 'eohunter', 'engine.rb'))
        match = source.match(PARTS_PATTERN)
        raise "cannot read EO::Engine::PARTS from engine.rb" unless match

        match[1].split
      end

      # Reuse the running hunt's policy classes, if present, without reloading.
      # @param script_dir [String] Lich script directory
      # @return [void]
      def load_support(script_dir)
        dir = File.join(script_dir, 'eohunter')
        unless defined?(::EO::Engine::Profile)
          ::EO.const_set(:Engine, Module.new) unless defined?(::EO::Engine)
          profile_parts(script_dir).each { |part| load File.join(dir, "#{part}.rb") }
        end
        # `load`, not `require`.
        #
        # The script drops EO::HunterSetup before calling this, so every edit
        # since the last run takes. `require` keys on the path and refuses to
        # re-read a file it has already seen, so after that drop the constants
        # were gone and require would not put them back: the second
        # `;eohunter setup` of a session died on an uninitialized constant.
        # The `unless const_defined?` guard made it worse rather than
        # protecting anything -- it is reached only when the constant is
        # missing, which is exactly when require does nothing.
        SETUP_PARTS.each { |part| load File.join(dir, 'setup', "#{part}.rb") }
      end

      # Build the editor's operations against this character's native storage
      # and read-only map and recovery inputs.
      #
      # @param data_dir [String] Lich data directory
      # @param game [String] active game instance
      # @param character [String] active character name
      # @param templates [Enumerable] native creature records
      # @param rooms [Enumerable] native map records
      # @param uid_resolver [#call] native UID lookup, without travel
      # @param ready_list [Hash] ReadyList slots and what is in them
      # @param inventory [Array<Hash>] carried items as {noun:, name:, types:}
      # @return [App] transport-independent editor operations
      # @param level [Integer] the character's level, for the creature finder's
      #   opening range
      # @param scripts [Array<String>, nil] installed script names, for the
      #   routine check; nil skips it
      def app(data_dir:, game:, character:, templates:, rooms:, uid_resolver:, level: 0,
              ready_list: {}, inventory: [], armaments: {}, scripts: nil)
        root = File.join(data_dir, game, character)
        store = Store.new(root: File.join(root, 'eohunter'), legacy_root: File.join(root, 'bigshot_profiles'))
        schema = Schema.new(profile_class: EO::Engine::Profile, cleanse_policy_class: EO::Engine::Cleanse::Policy)
        room_list = rooms.to_a.compact
        room_index = room_list.to_h { |room| [room.id.to_i, room] }
        geography = Geography.new(templates: templates, rooms: room_list, uid_resolver: uid_resolver)
        App.new(store: store, schema: schema, geography: geography,
                context: { character: character, game: game, level: level },
                uid_ids: uid_resolver, room_lookup: ->(id) { room_index[id.to_i] },
                hazards: Hazards.new(profile_class: EO::Engine::Profile),
                society_abilities: SocietyAbilities.capture,
                ready_list: ready_list, inventory: inventory, armaments: armaments, scripts: scripts)
      end
    end
  end
end
