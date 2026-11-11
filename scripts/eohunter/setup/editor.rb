# frozen_string_literal: true

module EO
  module HunterSetup
    # The editing session: the draft, what it was loaded from, and the last
    # validation of it.
    #
    # Ruby owns this state and the window is drawn from it. Nothing in
    # this class sends a game command or evaluates a profile expression --
    # execution remains the hunter's job.
    #
    # Callers mutate through the +on_*+ methods, which are what the page's
    # event handlers bind to. Each returns true when the page should be
    # re-rendered.
    class Editor
      # Titles for the schema's own page identities. The identities come from
      # Schema::PAGES rather than being repeated here: a settings page that
      # exists in the schema but not in this table would still get a tab, under
      # a generated title, instead of silently rendering nowhere.
      #
      # They label the sidebar, so they can say what the page is for.
      TITLES = {
        'area' => 'Where to hunt', 'creatures' => 'What to hunt', 'hunting' => 'Hunting behavior',
        'rest' => 'Rest',
        'recovery' => 'Recovery & emergencies', 'combat' => 'Combat',
        'equipment' => 'Gear',
        'team' => 'Multi-account team'
      }.freeze

      # Settings pages, in the schema's own order.
      SETTINGS_PAGES = Schema::PAGES.keys.freeze

      # The sidebar's sections, each naming the pages beneath it.
      #
      # The grouping is the one worked out in the design discussion -- profile
      # management, then the hunt itself, then how a fight is fought, then the
      # settings that only matter with other people.
      SECTIONS = [
        ['Profiles', %w[manage]],
        ['The hunt', %w[creatures area hunting]],
        ['Rest & recovery', %w[rest recovery]],
        ['Combat & equipment', %w[combat equipment]],
        ['Hunting with others', %w[team]]
      ].freeze

      # Pages that are not settings pages, with their titles and the section
      # they sit under.
      # Compare, from the design sketch, is deliberately absent: there is no
      # comparison page yet, and a sidebar item leading nowhere is worse than
      # one that is missing.
      EXTRA_TITLES = {
        'manage' => 'Hunts'
      }.freeze

      # The sidebar's items, in section order: id, label, section.
      #
      # Built from SECTIONS so a page named there but missing from the schema
      # cannot appear as an item leading nowhere.
      NAV_ITEMS = SECTIONS.flat_map do |(section, pages)|
        pages.filter_map do |page|
          next if SETTINGS_PAGES.none?(page) && !EXTRA_TITLES.key?(page)

          title = EXTRA_TITLES[page] || TITLES[page] || page.split('_').map(&:capitalize).join(' ')
          { id: page, label: title, section: section }
        end
      end.freeze

      attr_reader :app, :boot, :draft, :name, :kind, :revision, :validation, :status, :status_error,
                  :pending_delete

      # @param app [App] transport-independent editor operations
      def initialize(app:)
        @app = app
        @boot = app.call('action' => 'bootstrap')
        @kind = 'profiles'
        @name = ''
        @loaded_name = ''
        @revision = nil
        @draft = { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        @status = nil
        @status_error = false
        @pending_delete = nil
      end

      # Ask to delete a document. Holds the preview -- revision and what
      # depends on it -- so the confirmation can say what is at stake, and so
      # the delete is checked against the document as it was when asked about.
      # @param name [String] document basename
      # @param kind [String] document kind
      # @return [Boolean] whether to re-render
      def on_request_delete(name, kind: 'profiles')
        preview = delete_preview(name, kind: kind)
        return true unless preview

        @pending_delete = preview.merge(kind: kind, name: name)
        true
      end

      # Abandon a delete that was asked about but not confirmed.
      # @return [Boolean] whether to re-render
      def on_cancel_delete
        @pending_delete = nil
        true
      end

      # Carry out the delete the pending preview describes.
      # @return [Boolean] whether to re-render
      def on_confirm_delete
        pending = @pending_delete
        return true unless pending

        @pending_delete = nil
        on_delete(pending[:name], pending[:revision], kind: pending[:kind])
      end

      # Settings only a Ranger can use, hidden from everyone else.
      RANGER_ONLY = %w[track track_creature].freeze

      # @return [Array<Hash>] every field descriptor the schema publishes
      #   that this character can use
      def fields
        all = @boot[:fields] || @boot['fields'] || []
        ranger? ? all : all.reject { |field| RANGER_ONLY.include?(field['key']) }
      end

      # @return [Boolean] whether the character is a Ranger; false when the
      #   profession is not known
      def ranger?
        context = @boot[:context] || @boot['context'] || {}
        (context[:profession] || context['profession']).to_s.match?(/ranger/i)
      end

      # @param page [String] settings page identity
      # @return [Array<Hash>] that page's field descriptors, schema order
      def fields_for(page)
        fields.select { |field| field['page'] == page }
      end

      # Counts each time the whole draft is replaced. Lich keeps what a viewer
      # sees in a box by the box's identity and ignores a later redraw's value,
      # so the page's outer key carries this: a replaced draft gets new boxes,
      # filled from the draft, and not the last hunt's values or blanks.
      # @return [Integer]
      def draft_serial = @draft_serial || 0

      # @return [Hash] this draft's settings, never nil
      def settings = @draft['settings'] ||= {}

      # @return [Boolean] whether the draft differs from what was loaded
      def dirty?
        @draft != @baseline || @name != @loaded_name
      end

      # @return [Array<String>] native profile names
      def profiles = Array(@boot[:profiles] || @boot['profiles'])

      # @return [Hash] ReadyList slots and what is readied in them
      def ready_list = @boot[:ready_list] || @boot['ready_list'] || {}

      # @return [Array] carried items, for the hand and ammunition pickers
      def inventory = Array(@boot[:inventory] || @boot['inventory'])

      # Replace the equipment the pickers offer.
      #
      # The editor opens before the game has been asked for a ready list or an
      # inventory, because both block and neither is worth an unresponsive
      # window. This is how the answers reach the pickers when they arrive.
      # @param ready_list [Hash] ReadyList slots and what is in them
      # @param inventory [Array] carried items
      # @return [void]
      def equipment=(replacement)
        @boot = @boot.merge(
          ready_list: replacement[:ready_list] || ready_list,
          inventory: replacement[:inventory] || inventory
        )
      end

      # Choose a hand or ammunition value from the picker.
      #
      # The "something else" choice is not a value: it clears the setting and
      # lets the text field beside it carry what is typed. Clearing rather
      # than keeping the old value is deliberate -- the player has just said
      # the old value was not what they meant.
      # @param key [String] setting key
      # @param value [String] chosen option value
      # @return [Boolean] whether to re-render
      def on_equipment(key, value)
        on_change(key, value.to_s == Page::OTHER ? '' : value)
        true
      end

      # The choices for a setting the character's own equipment can answer.
      #
      # Returns nil for every other setting, which is how the renderer decides
      # between a picker and a plain text field.
      # @param key [String] setting key
      # @return [Array<Hash>, nil] option records
      def equipment_options(key)
        case key.to_s
        when 'hunting_right_hand'
          Equipment.hand_options('right', ready: ready_list, inventory: inventory, armaments: armaments)
        when 'hunting_left_hand'
          Equipment.hand_options('left', ready: ready_list, inventory: inventory, armaments: armaments)
        when 'ammo'
          Equipment.ammo_options(ready: ready_list, inventory: inventory)
        end
      end

      # @return [Hash] Lich's weapon and shield name tables, which is how an
      #   item is recognised when the type data does not name it
      def armaments = @boot[:armaments] || @boot['armaments'] || {}

      # @return [Array<String>] read-only Bigshot profiles, openable as copies
      def legacy_profiles = Array(@boot[:legacy_profiles] || @boot['legacy_profiles'])

      # @return [Hash] hidden names and the argument-free launch default
      def visibility
        @boot[:profile_visibility] || @boot['profile_visibility'] || {}
      end

      # @return [String, nil] the profile a bare ;eohunter starts
      def active_profile = visibility[:active_profile] || visibility['active_profile']

      # @param name [String] profile basename
      # @param source [Symbol] :native or :legacy
      # @return [Boolean] whether the list hides this name
      def hidden?(name, source: :native)
        hidden = visibility[:hidden] || visibility['hidden'] || {}
        Array(hidden[source.to_s]).include?(name)
      end

      # Choose the profile an argument-free `;eohunter` starts. Selecting one
      # never starts a hunt.
      # @param name [String, nil] profile basename, or nil to clear
      # @return [Boolean] whether to re-render
      def on_set_active(name)
        @app.call('action' => 'set_active_profile', 'name' => name,
                  'revision' => visibility[:revision] || visibility['revision'])
        refresh_boot
        note(name ? "#{name} is now the default hunt. This did not start it." : 'Cleared the default hunt.')
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Hide or show a name in the list, without touching either profile.
      # @param name [String] profile basename
      # @param hidden [Boolean] desired state
      # @param source [Symbol] :native or :legacy
      # @return [Boolean] whether to re-render
      def on_set_hidden(name, hidden, source: :native)
        @app.call('action' => 'profile_visibility', 'name' => name, 'source' => source.to_s,
                  'hidden' => hidden, 'revision' => visibility[:revision] || visibility['revision'])
        refresh_boot
        note("#{hidden ? 'Hid' : 'Restored'} #{name}.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # What deleting this document would take with it. Asked before the
      # confirmation dialog, so the dialog can say what is at stake.
      # @param name [String] document basename
      # @param kind [String] document kind
      # @return [Hash, nil] revision, dependents and legacy fallback
      def delete_preview(name, kind: 'profiles')
        @app.call('action' => 'delete_preview', 'kind' => kind, 'name' => name)
      rescue StandardError => error
        note(error.message, error: true)
        nil
      end

      # Delete a native document, keeping a recoverable backup. Requires the
      # revision from the preview, so a document edited in between is refused.
      # @param name [String] document basename
      # @param revision [String] digest from delete_preview
      # @param kind [String] document kind
      # @return [Boolean] whether to re-render
      def on_delete(name, revision, kind: 'profiles')
        @app.call('action' => 'delete_document', 'kind' => kind, 'name' => name,
                  'revision' => revision, 'confirm' => true)
        refresh_boot
        if @loaded_name == name && @kind == kind
          @name = ''
          @loaded_name = ''
          @revision = nil
          @draft = { 'schema_version' => 1, 'settings' => {} }
          @baseline = deep_copy(@draft)
          @draft_serial = draft_serial + 1
        end
        note("Deleted #{name}. A backup was kept.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Start a new, empty draft. Nothing is written until it is saved.
      # @return [Boolean] whether to re-render
      def on_new
        @kind = 'profiles'
        @name = ''
        @loaded_name = ''
        @revision = nil
        @draft = { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        @sheet = nil
        @map_frame = nil
        @draft_serial = draft_serial + 1
        note('Started a new hunt. Name it, then save.')
      end

      # Open a read-only Bigshot profile as an unsaved copy. The original is
      # never written to: saving creates an EOHunter-owned document.
      # @param name [String] legacy basename
      # @return [Boolean] whether to re-render
      def on_copy_legacy(name)
        document = @app.call('action' => 'read', 'kind' => 'profiles', 'name' => name, 'source' => 'legacy')
        @kind = 'profiles'
        @name = name
        @loaded_name = ''
        @revision = nil
        # A Bigshot profile is the settings themselves, one flat mapping; an
        # EOHunter hunt holds them under `settings`. Left flat, every key sat
        # beside `settings` where no control looks, and the copy opened empty.
        data = document[:data] || {}
        data = { 'schema_version' => 1, 'settings' => data } unless data.key?('settings')
        # Only what eohunter reads comes across. The hunt it saves is not a
        # Bigshot profile and is not kept compatible with one, so Bigshot's
        # bookkeeping and the features eohunter does not have would be
        # carried for nothing. Empty values are unset in all but name.
        known = fields.to_set { |field| field['key'] }
        kept, dropped = data['settings'].to_h.partition do |key, value|
          known.include?(key) && !(value.nil? || value == '')
        end
        data['settings'] = kept.to_h
        @draft = data
        @baseline = { 'schema_version' => 1, 'settings' => {} }
        @draft_serial = draft_serial + 1
        @validation = nil
        @map = nil
        unused = dropped.count { |(key, _)| !known.include?(key) }
        left = unused.zero? ? '' : " Left out #{unused} Bigshot setting#{'s' if unused != 1} eohunter does not use."
        note("Opened the Bigshot profile #{name} as a copy. Saving creates an EOHunter hunt; " \
             "the original is left alone.#{left}")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Load a stored document into the draft, replacing anything unsaved.
      # @param name [String] document basename
      # @param kind [String] profiles, defaults, plans or injury_policies
      # @return [Boolean] whether to re-render
      def on_load(name, kind: 'profiles')
        document = @app.call('action' => 'read', 'kind' => kind, 'name' => name)
        @kind = kind
        @name = name
        @loaded_name = name
        @revision = document[:revision]
        @draft = document[:data] || { 'schema_version' => 1, 'settings' => {} }
        @baseline = deep_copy(@draft)
        @validation = nil
        @map = nil
        @sheet = nil
        @map_frame = nil
        @draft_serial = draft_serial + 1
        note("Loaded #{name}.")
      rescue StandardError => error
        # The list is rebuilt from disk before the message, so a hunt that has
        # gone missing stops being offered rather than staying on screen with
        # an Edit button that keeps failing.
        refresh_boot
        note("Could not open #{name}: #{error.message}", error: true)
      end

      # Set one setting, or remove it when the value is blank. Removing is how
      # a hunt falls back to its inherited or engine default, so an emptied
      # field must not persist as an empty string.
      # @param key [String] native setting key
      # @param value [Object] cleaned value
      # @return [Boolean] whether to re-render
      def on_change(key, value)
        if value.nil? || value == ''
          settings.delete(key)
        else
          settings[key] = value
        end
        @validation = nil
        @map = nil
        true
      end

      # Hunting areas the installed creature and map data know about, with the
      # creatures and map sheets each one has. Read once: the catalogue is
      # derived from installed data, not from the draft.
      # @return [Array<Hash>] area records, or [] when there is no map data
      def areas
        @areas ||= Array(@app.call('action' => 'areas'))
      rescue StandardError
        @areas = []
      end

      # --- Finding something to hunt ---------------------------------------
      #
      # The question a player arrives with is "what can I fight", and the
      # area follows from the answer. See Creatures.

      # @return [Integer] the character's level, or 0 when it is not known
      def character_level
        context = @boot[:context] || @boot['context'] || {}
        (context[:level] || context['level']).to_i
      end

      # @return [Hash] the search as it stands
      def hunt_query
        @hunt_query ||= Creatures.default_range(character_level).merge(traits: {})
      end

      # Every creature the installed templates know, described.
      # @return [Array<Hash>]
      def creature_catalogue
        @creature_catalogue ||= Array(@app.call('action' => 'creatures'))
      rescue StandardError => error
        @creature_error = error.message
        @creature_catalogue = []
      end

      # @return [String, nil] why the creature catalogue could not be read
      attr_reader :creature_error

      # The creatures matching the search.
      # @return [Array<Hash>]
      def creature_matches = Creatures.search(creature_catalogue, hunt_query)

      # What the creature list is sorted by.
      CREATURE_SORTS = { 'level' => 'Level', 'name' => 'Creature', 'family' => 'Family', 'areas' => 'Lives in' }.freeze

      # @return [String] a CREATURE_SORTS key
      def creature_sort = @creature_sort || 'level'

      # The matches in the chosen order, ties by level then name.
      # @return [Array<Hash>]
      def sorted_creature_matches
        creature_matches.sort_by do |creature|
          first = case creature_sort
                  when 'name' then creature[:name].to_s.downcase
                  when 'family' then creature[:family].to_s.downcase
                  when 'areas' then Array(creature[:areas]).join(', ').downcase
                  else format('%04d', creature[:level].to_i)
                  end
          [first, creature[:level].to_i, creature[:name].to_s.downcase]
        end
      end

      # Sort the creature list.
      # @param key [String] a CREATURE_SORTS key
      # @return [Boolean] whether to re-render
      def on_creature_sort(key)
        @creature_sort = CREATURE_SORTS.key?(key.to_s) ? key.to_s : 'level'
        true
      end

      # How many creatures the level band cannot place, having no recorded
      # level. They are found by name.
      # @return [Integer]
      def unlevelled_count = creature_catalogue.count { |creature| creature[:level].nil? }

      # Change one part of the search.
      # @param field [Symbol, String] a key of the query
      # @param value [Object] its new value, nil to clear
      # @return [Boolean] whether to re-render
      def on_hunt_filter(field, value)
        key = field.to_sym
        if Creatures::SPARSE.include?(key)
          hunt_query[:traits] = hunt_query[:traits].merge(key => value)
          hunt_query[:traits].compact!
        elsif value.nil? || value == '' || value == []
          hunt_query.delete(key)
        else
          hunt_query[key] = value
        end
        true
      end

      # @param trait [Symbol] a sparse trait
      # @return [Hash] {yes:, no:, unknown:} over the current matches
      def trait_tally(trait) = Creatures.trait_tally(creature_matches, trait)

      # @return [String, nil] the area name the draft names
      def area_name = @draft['area'] || settings['area']

      # Recompute boundaries for a hand-picked set of rooms, using the same
      # walker the hunt itself uses. Refuses rather than silently widening.
      # @param room_ids [Array<Integer>] the rooms to hunt
      # @param start_room_id [Integer] which one to start in
      # @return [Boolean] whether to re-render
      def on_room_geometry(room_ids, start_room_id)
        result = @app.call('action' => 'room_geometry', 'room_ids' => room_ids,
                           'start_room_id' => start_room_id)
        on_change('hunting_room_id', result[:start_room_id])
        write_list('hunting_boundaries', Array(result[:boundary_ids]).map(&:to_s))
        note("Recomputed: #{Array(result[:room_ids]).size} rooms, #{Array(result[:boundary_ids]).size} boundaries.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # @return [String] the current search text
      def query = @query.to_s

      # Find settings by label, key, help text or a familiar legacy name.
      #
      # @param text [String] search terms
      # @return [Boolean] whether to re-render
      def on_search(text)
        @query = text.to_s.strip
        true
      end

      # @return [Array<Hash>] fields matching every term in the query
      def search_results
        return [] if query.empty?

        terms = query.downcase.split
        fields.select do |field|
          haystack = [field['key'], field['label'], field['help'], *Array(field['aliases'])].join(' ').downcase
          terms.all? { |term| haystack.include?(term) }
        end
      end

      # What this draft changes against what was last loaded, as a list of
      # before/after pairs. Answers "what am I about to save?" without
      # reading two YAML dumps side by side.
      # @return [Array<Hash>] key, before and after
      def changes
        keys = (@baseline['settings'].to_h.keys + settings.keys).uniq.sort
        keys.filter_map do |key|
          before = @baseline['settings'].to_h[key]
          after = settings[key]
          next if before == after

          { 'key' => key, 'before' => before, 'after' => after }
        end
      end

      # Entries of a comma-list setting, in order.
      # @param key [String] native setting key
      # @return [Array<String>]
      def list_entries(key)
        value = settings[key]
        return [] if value.nil?
        return value.map(&:to_s) if value.is_a?(Array)

        value.to_s.split(',').map(&:strip).reject(&:empty?)
      end

      # Replace one entry, dropping it when it is blanked.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @param value [String] its new text
      # @return [Boolean] whether to re-render
      def on_list_set(key, index, value)
        entries = list_entries(key)
        return false unless index.between?(0, entries.size - 1)

        text = value.to_s.strip
        text.empty? ? entries.delete_at(index) : entries[index] = text
        write_list(key, entries)
      end

      # Append an entry. Blank input is not an entry.
      # @param key [String] native setting key
      # @param value [String] the new entry
      # @return [Boolean] whether to re-render
      def on_list_add(key, value)
        text = value.to_s.strip
        return false if text.empty?

        write_list(key, list_entries(key) + [text])
      end

      # Replace a list wholesale.
      #
      # Takes the whole list rather than one edit, so adding, removing and reordering all arrive here as the new
      # list. Blanks are dropped and duplicates collapse: the same room named
      # twice is one boundary.
      # @param key [String] native setting key
      # @param values [Array<String>] the list as it now stands
      # @return [Boolean] whether to re-render
      def on_list_set_all(key, values)
        entries = Array(values).map { |value| value.to_s.strip }.reject(&:empty?).uniq
        write_list(key, entries)
      end

      # Fill a list with everything the area offers for it.
      # @param key [String] native setting key
      # @return [Boolean] whether to re-render
      def on_list_fill(key)
        offered = Page.list_suggestions(self, 'key' => key.to_s)
        return false if offered.empty?

        write_list(key, (list_entries(key) + offered).uniq)
      end

      # Empty a list.
      # @param key [String] native setting key
      # @return [Boolean] whether to re-render
      def on_list_clear(key)
        return false if list_entries(key).empty?

        write_list(key, [])
      end

      # Drop one entry.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @return [Boolean] whether to re-render
      def on_list_remove(key, index)
        entries = list_entries(key)
        return false unless index.between?(0, entries.size - 1)

        entries.delete_at(index)
        write_list(key, entries)
      end

      # Move an entry. Order is meaningful for scripts and command lists, so
      # this is the reason these are edited as rows rather than one text field.
      # @param key [String] native setting key
      # @param index [Integer] which entry
      # @param offset [Integer] -1 for up, 1 for down
      # @return [Boolean] whether to re-render
      def on_list_move(key, index, offset)
        entries = list_entries(key)
        target = index + offset
        return false unless index.between?(0, entries.size - 1) && target.between?(0, entries.size - 1)

        entries[index], entries[target] = entries[target], entries[index]
        write_list(key, entries)
      end

      # Rename the draft without touching what is on disk. Saving under a new
      # name creates a new document; the original is left alone.
      # @param name [String] new basename
      # @return [Boolean] whether to re-render
      def on_rename(name)
        @name = name.to_s.strip
        true
      end

      # Check the draft against the installed engine, without saving.
      # @return [Boolean] whether to re-render
      def on_validate
        @validation = @app.call('action' => 'validate', 'data' => @draft, 'kind' => @kind)
        note(validation_summary)
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Write the draft, honouring the revision read with it.
      # @return [Boolean] whether to re-render
      def on_save
        return note('Name this hunt before saving.', error: true) if @name.empty?

        # A new name is a new hunt: the store takes no revision for a file
        # that does not exist, and refuses one that does rather than writing
        # over a hunt that was never opened.
        renamed = @name != @loaded_name
        if renamed && profiles.include?(@name)
          return note("A hunt named #{@name} already exists. Open it to change it, or pick another name.", error: true)
        end

        saved = @app.call('action' => 'save', 'kind' => @kind, 'name' => @name,
                          'data' => @draft, 'revision' => renamed ? nil : @revision)
        @revision = saved[:revision]
        @loaded_name = @name
        @baseline = deep_copy(@draft)
        refresh_boot
        note("Saved #{@name}. Saving does not start a hunt.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Discard unsaved edits, returning to the last loaded state.
      # @return [Boolean] whether to re-render
      def on_revert
        @draft = deep_copy(@baseline)
        @name = @loaded_name
        @draft_serial = draft_serial + 1
        @validation = nil
        @map = nil
        note('Reverted to the last saved version.')
      end

      # @param key [String] a Cleanse preference
      # @return [Object, nil] what this hunt says about it
      def recovery_value(key) = recovery_settings[key]

      # Why this character cannot use a Cleanse choice, read when setup
      # opened; nil when it can, or when Lich could not say.
      # @param key [String] a Cleanse preference
      # @return [String, nil]
      def recovery_unusable(key)
        found = @boot[:recovery_unusable] || @boot['recovery_unusable'] || {}
        found[key] || found[key.to_sym]
      end

      # Set one Cleanse preference. Off is simply absent, and ecleanse's window
      # allows one stunman choice, so ticking one clears the others.
      # @param key [String] a Cleanse preference
      # @param value [Boolean, String]
      # @return [Boolean] whether to re-render
      def on_recovery_set(key, value)
        wanted = recovery_settings.dup
        Schema::RECOVERY_EXCLUSIVE.each { |other| wanted.delete(other) } if value == true && Schema::RECOVERY_EXCLUSIVE.include?(key)
        if value == true || (value.is_a?(String) && !value.empty?)
          wanted[key] = value
        else
          wanted.delete(key)
        end
        wanted.empty? ? settings.delete('recovery') : settings['recovery'] = wanted
        @validation = nil
        # Lich keeps a tick by its identity, so clearing a stunman choice from
        # here needs new boxes; typing in the safe room must keep its box.
        @draft_serial = draft_serial + 1 if value == true && Schema::RECOVERY_EXCLUSIVE.include?(key)
        true
      end

      # @return [Boolean] whether standalone ecleanse has anything to import
      def ecleanse_to_import?
        !ecleanse_settings.empty?
      end

      # Copy standalone ecleanse's preferences into this draft, replacing the
      # draft's, less any this character cannot use, as ecleanse's own window
      # switches those off. Nothing is written until the hunt is saved.
      # @return [Boolean] whether to re-render
      def on_import_ecleanse
        found = ecleanse_settings
        return note('ecleanse has nothing set to import.', error: true) if found.empty?

        skipped = found.keys.select { |key| recovery_unusable(key) }
        found = found.reject { |key, _| skipped.include?(key) }
        found.empty? ? settings.delete('recovery') : settings['recovery'] = found
        @validation = nil
        @draft_serial = draft_serial + 1
        left_out = skipped.empty? ? '' : " Left out #{skipped.size} this character cannot use."
        note("Imported #{found.size} ecleanse setting#{'s' if found.size != 1}.#{left_out} Save to keep them.")
      end

      # What each room role is called.
      ROLE_LABELS = {
        'hunting' => 'Hunting room', 'hunting_boundaries' => 'Boundary',
        'hunting_room_id' => 'Starting room', 'rallypoint_room_ids' => 'Rally room',
        'field_rest_room_id' => 'Field rest', 'resting_room_id' => 'Town rest',
        'creature' => 'Where the picked creature lives'
      }.freeze

      # The roles that hold several rooms, as comma text.
      LIST_ROLES = %w[hunting_boundaries rallypoint_room_ids].freeze

      # @return [String, nil] the map sheet being looked at
      attr_reader :sheet

      # The area record the map is drawn for, when the draft names one.
      # @return [Hash, nil]
      def map_area
        name = area_name
        return nil if name.to_s.empty?

        areas.find { |entry| entry[:name].to_s == name.to_s }
      end

      # The draft's rooms, laid out on an installed map sheet. Recomputed from
      # the draft rather than cached, so it always describes what is loaded.
      # @return [Hash, nil] markers, rooms and diagnostics, or nil if unavailable
      def map
        # The chosen area anchors which rooms the map shows, so the picture
        # survives a draft with nothing marked in it: see Geography#profile_map.
        @map ||= @app.call('action' => 'profile_map', 'settings' => settings,
                           'sheet' => @sheet, 'area' => map_area)
      rescue StandardError => error
        @map_error = error.message
        nil
      end

      # @return [String, nil] why the map could not be built
      attr_reader :map_error

      # Look at a different sheet without changing the draft.
      # @param sheet [String] map image filename
      # @return [Boolean] whether to re-render
      def on_sheet(sheet)
        @sheet = sheet.to_s.empty? ? nil : sheet.to_s
        @sheet_choices = []
        @map = nil
        @map_frame = nil
        true
      end

      # Which role a room holds, if any.
      # @param id [Integer] room id
      # @return [String, nil] role key
      def role_for(id)
        current = map
        return nil unless current

        markers = current[:markers] || {}
        return 'hunting_room_id' if markers['hunting_room_id'] == id
        return 'hunting_boundaries' if Array(markers['hunting_boundaries']).include?(id)
        return 'rallypoint_room_ids' if Array(markers['rallypoint_room_ids']).include?(id)
        return 'field_rest_room_id' if markers['field_rest_room_id'] == id
        return 'resting_room_id' if markers['resting_room_id'] == id
        return 'hunting' if Array(current[:hunting_room_ids]).include?(id)

        nil
      end

      # Put a room in a role, or clear it. A single-room role replaces whatever
      # held it; boundaries are a list, so a room toggles in and out.
      # @param role [String] one of ROLE_LABELS' keys
      # @param id [Integer] room id
      # @return [Boolean] whether to re-render
      def on_assign_room(role, id)
        case role
        when *LIST_ROLES
          current = settings[role]
          list = current.is_a?(Array) ? current.map(&:to_s) : current.to_s.split(',').map(&:strip)
          list.reject!(&:empty?)
          return on_clear_room(role, id) if list.include?(id.to_s)

          list << id.to_s
          # A comma string, not an Array: the `rooms` cleaner splits a string,
          # and handed an Array it stringifies it -- ["101"] round-trips as
          # ["[\"101\"]"]. Every list-shaped setting here is stored as text.
          on_change(role, list.join(', '))
        when 'hunting_room_id', 'field_rest_room_id', 'resting_room_id'
          # A click on the room that holds the role takes it away; a click
          # anywhere else moves the role there.
          return on_clear_room(role, id) if settings[role].to_s == id.to_s
          # With a creature picked, the hunt starts where it lives: from
          # anywhere else the boundaries, which ring its rooms, do not keep
          # the walk to them, and it meets none of it.
          if role == 'hunting_room_id' && !fence_rooms.empty? && !fence_rooms.include?(id.to_i)
            return note("Room #{id} is not where #{fence_creature} lives. Pick one of its rooms, outlined in teal.", error: true)
          end

          on_change(role, id)
        else
          return note("#{role} is not a room role.", error: true)
        end
        @map = nil
        note("#{ROLE_LABELS.fetch(role, role)}: room #{id}.")
      end

      # Take a room out of a role.
      # @param role [String] one of ROLE_LABELS' keys
      # @param id [Integer] room id
      # @return [Boolean] whether to re-render
      def on_clear_room(role, id)
        case role
        when *LIST_ROLES
          list = settings[role].to_s.split(',').map(&:strip).reject(&:empty?)
          list.delete(id.to_s)
          on_change(role, list.join(', '))
        when 'hunting_room_id', 'field_rest_room_id', 'resting_room_id'
          return note("Room #{id} is not the #{ROLE_LABELS.fetch(role).downcase}.") unless settings[role].to_s == id.to_s

          on_change(role, '')
        else
          return note("#{role} is not a room role.", error: true)
        end
        @map = nil
        note("#{ROLE_LABELS.fetch(role, role)} cleared: room #{id}.")
      end

      # Room roles and the colour each is drawn in on the map. More roles
      # than the contract's four tones, so these are RGBA.
      ROLE_COLOURS = {
        'hunting'             => { 'r' => 30, 'g' => 150, 'b' => 50, 'a' => 0.95 },
        'hunting_boundaries'  => { 'r' => 220, 'g' => 54, 'b' => 46, 'a' => 0.95 },
        'hunting_room_id'     => { 'r' => 47, 'g' => 109, 'b' => 214, 'a' => 0.95 },
        'rallypoint_room_ids' => { 'r' => 230, 'g' => 150, 'b' => 30, 'a' => 0.95 },
        'field_rest_room_id'  => { 'r' => 138, 'g' => 79, 'b' => 201, 'a' => 0.6 },
        'resting_room_id'     => { 'r' => 201, 'g' => 70, 'b' => 120, 'a' => 0.6 },
        'creature'            => { 'r' => 0, 'g' => 150, 'b' => 160, 'a' => 0.9 }
      }.freeze

      # How far the map can be zoomed: a range a player can get back from.
      MAP_SCALE_RANGE = (0.4..4.0).freeze

      # How much one zoom step changes it.
      MAP_SCALE_STEP = 1.25

      # @return [Float] the map's zoom, on top of fitting the hunt to the view
      def map_scale = @map_scale || 1.0

      # Zoom the map a step in or out, from the centre.
      # @param direction [String] 'in' or 'out'
      # @return [Boolean] whether to re-render
      def on_map_zoom(direction)
        factor = direction.to_s == 'out' ? (1.0 / MAP_SCALE_STEP) : MAP_SCALE_STEP
        @map_scale = (map_scale * factor).round(3).clamp(MAP_SCALE_RANGE.begin, MAP_SCALE_RANGE.end)
        true
      end

      # Back to the fitted size.
      # @return [Boolean] whether to re-render
      def on_map_reset_zoom
        @map_scale = 1.0
        true
      end

      # The window the page opens at, width and height, until a viewer
      # reports its real size.
      DEFAULT_WINDOW = [1180, 760].freeze

      # What the page's padding, the map group's own padding and a scrollbar
      # take from the window's width before the map view gets the rest.
      MAP_CHROME_WIDTH = 96

      # What the rail of pages takes beside the map.
      RAIL_WIDTH = 240

      # What sits above and below the map view: the page's toolbar, the
      # step bar, the map's controls and legend, its status line.
      MAP_CHROME_HEIGHT = 330

      # The window as the viewer last reported it, set by the launcher before
      # each refresh; nil until one has.
      # @return [Hash{Symbol => Integer}, nil] width and height
      attr_accessor :window_size

      # How wide the map view is: the sheet is scaled to fill it.
      # @return [Integer] pixels
      def map_fit_width
        width = (window_size&.dig(:width) || DEFAULT_WINDOW[0]) - MAP_CHROME_WIDTH
        width -= RAIL_WIDTH
        [width, 320].max
      end

      # How tall the map view may be before it scrolls.
      # @return [Integer] pixels
      def map_view_height
        [(window_size&.dig(:height) || DEFAULT_WINDOW[1]) - MAP_CHROME_HEIGHT, 320].max
      end

      # Keep looking at this sheet until the viewer picks another. The map's
      # rooms follow the walk, so a boundary taken away can send the walk
      # onto other sheets; the one with the most rooms would then be shown,
      # which is not the one being edited.
      # @param sheet [String, nil] map image filename
      # @return [void]
      def keep_sheet(sheet)
        @sheet ||= sheet unless sheet.to_s.empty?
      end

      # Which of the full editor's pages is being looked at. Only that one
      # is drawn in full: drawing all fourteen on every refresh, the open
      # map among them, made each tick a whole-page rebuild in the browser,
      # and clicks that landed during the rebuild were lost.
      # @return [Integer] index into Schema::PAGES
      def page_index = @page_index || 0

      # Look at another page.
      # @param index [Integer]
      # @return [Boolean] whether to re-render
      def on_select_page(index)
        index = index.to_i
        return false if index.negative? || index == page_index

        @page_index = index
        true
      end

      # Look at a page by its id, as in NAV_ITEMS.
      # @param id [String]
      # @return [Boolean] whether to re-render
      def on_show_page(id)
        index = NAV_ITEMS.index { |item| item[:id] == id.to_s }
        index ? on_select_page(index) : false
      end

      # The page tabs' component ID in the last render, so the session can
      # set which tab the viewer has selected.
      # @return [String, nil]
      attr_accessor :tabs_cid

      # --- What lives in the hunt's rooms, and the boons ---------------------

      # @return [Array<Hash>] the boons the target reader knows: key, label,
      #   adjectives and effect
      def boon_abilities = Array(@boot[:boon_abilities] || @boot['boon_abilities'])

      # @param name [String] a folded group's heading
      # @return [Boolean] whether that group is open
      def fold_open?(name) = (@open_folds ||= {})[name] == true

      # Open or close a folded group.
      # @param name [String] its heading
      # @return [Boolean] whether to re-render
      def on_toggle_fold(name)
        (@open_folds ||= {})[name] = !fold_open?(name)
        true
      end

      # The rooms the hunt walks from its start, inside its boundaries.
      # @return [Array<Integer>]
      def hunt_rooms
        return [] if settings['hunting_room_id'].to_s.empty?

        Array(map && map[:hunting_room_ids])
      end

      # The rooms the last pick fenced, for this draft only.
      # @return [Array<Integer>]
      def fence_rooms = fence_part(:rooms) || []

      # One part of the last pick's fence, for this draft only.
      def fence_part(part) = @fence && @fence[:serial] == draft_serial ? @fence[part] : nil

      # The fence's separate areas, each a list of room ids, largest first.
      # @return [Array<Array<Integer>>]
      def fence_areas = fence_part(:areas) || []

      # The creature the fence was made for, for this draft.
      # @return [String, nil]
      def fence_creature = fence_part(:creature)

      # Before a start room: the creatures of each of the fence's areas,
      # when there is more than one. A hunt walks one area, so a list of
      # them all mixed creatures it would never meet in with those it would.
      # @return [Array<Hash>] rooms and creatures per area; empty when the
      #   hunt has a start room or the fence is one area
      def creatures_by_area
        areas = fence_areas
        return [] if areas.size < 2 || !hunt_rooms.empty?

        if @creatures_by_area_for != areas
          @creatures_by_area_for = areas
          @creatures_by_area = areas.map do |rooms|
            { rooms: rooms, creatures: Array(@app.call('action' => 'creatures_here', 'room_ids' => rooms))
                                       .sort_by { |creature| [creature[:level] || 999, creature[:name].to_s] } }
          end
        end
        @creatures_by_area
      rescue StandardError => error
        note(error.message, error: true)
        []
      end

      # The creatures the templates place in the rooms the hunt walks now,
      # by level then name. Empty when the hunt has no rooms yet.
      # @return [Array<Hash>] name, level, undead
      def creatures_here
        rooms = hunt_rooms
        rooms = fence_rooms if rooms.empty?
        return [] if rooms.empty?

        if @creatures_here_for != rooms
          @creatures_here_for = rooms
          @creatures_here = Array(@app.call('action' => 'creatures_here', 'room_ids' => rooms))
                            .sort_by { |creature| [creature[:level] || 999, creature[:name].to_s] }
        end
        @creatures_here
      rescue StandardError => error
        note(error.message, error: true)
        []
      end

      # Whether any creature in the hunt's rooms is a boss type, which is
      # what can carry boons.
      # @return [Boolean]
      def boss_here?
        creatures_here.any? { |creature| creature[:boss] == true || !creature[:boss_type].to_s.empty? }
      end

      # Whether the boon settings are worth showing: a boss type is in the
      # hunt's rooms, or a boon box already says something. Otherwise they
      # are clutter.
      # @return [Boolean]
      def boons_relevant?
        %w[boons_ignore boons_flee].any? { |key| !list_entries(key).empty? } || boss_here?
      end

      # Whether a creature is in a list: by its name, before any marker such
      # as the (b) a target may carry.
      # @param key [String] a list setting
      # @param name [String] creature name
      # @return [Boolean]
      def listed?(key, name)
        list_entries(key).any? { |entry| entry.split('(').first.strip.casecmp?(name.to_s) }
      end

      # Hunt a creature, or leave it alone: in one of the two lists and out
      # of the other.
      # @param name [String] creature name
      # @param hunt [Boolean] true to hunt it, false to leave it alone
      # @return [Boolean] whether to re-render
      def on_hunt_creature(name, hunt)
        add, drop = hunt ? %w[targets invalid_targets] : %w[invalid_targets targets]
        write_list(drop, list_entries(drop).reject { |entry| entry.split('(').first.strip.casecmp?(name.to_s) })
        write_list(add, (list_entries(add) + [name.to_s]).uniq) unless listed?(add, name)
        note("#{name}: #{hunt ? 'hunting' : 'left alone'}.")
      end

      # Hunt every one of these: all into targets, none left in invalid_targets.
      # @param names [Array<String>] creature names
      # @return [Boolean] whether to re-render
      def on_hunt_all(names)
        names = Array(names).map(&:to_s).reject(&:empty?)
        return false if names.empty?

        write_list('invalid_targets', list_entries('invalid_targets').reject { |entry| names.any? { |name| entry.split('(').first.strip.casecmp?(name) } })
        write_list('targets', (list_entries('targets') + names.reject { |name| listed?('targets', name) }).uniq)
        note("Hunting all #{names.size} creatures here.")
      end

      # Whether the known boons are shown under a boon box.
      # @param key [String] 'boons_ignore' or 'boons_flee'
      # @return [Boolean]
      def boons_open?(key) = Array(@boons_open).include?(key.to_s)

      # Show or hide the known boons under a boon box.
      # @return [Boolean] whether to re-render
      def on_toggle_boons(key)
        @boons_open = Array(@boons_open)
        boons_open?(key) ? @boons_open.delete(key.to_s) : @boons_open << key.to_s
        true
      end

      # Put a boon in a boon list, or take it out.
      # @param key [String] 'boons_ignore' or 'boons_flee'
      # @param boon [String] the target reader's ability name
      # @param on [Boolean]
      # @return [Boolean] whether to re-render
      def on_toggle_boon(key, boon, on)
        entries = list_entries(key).reject { |entry| entry.casecmp?(boon.to_s) }
        entries << boon.to_s if on
        write_list(key, entries)
      end

      # Every place name the map knows, for filling in as the viewer types.
      # @return [Array<Hash>] name and image
      def area_names
        @area_names ||= Array(@app.call('action' => 'area_names'))
      rescue StandardError
        @area_names = []
      end

      # @return [String] what was last typed into the map's finder
      def room_query = @room_query.to_s

      # What is in the finder now, kept so a redraw while typing does not
      # take it away; the search itself waits for the typing to pause.
      # @param text [String]
      def room_query=(text)
        @room_query = text.to_s
      end

      # @return [Array<Hash>] the rooms the finder found, when more than one
      def room_matches = Array(@room_matches)

      # Find where to look: a place name goes straight to its sheet; anything
      # else is looked for in room titles, and a single find is shown, while
      # several are offered to choose from.
      # @param query [String] a place name, part of a room title, an id or uNNNN
      # @return [Boolean] whether to re-render
      def on_find_room(query)
        @room_query = query.to_s.strip
        @room_matches = []
        @sheet_choices = []
        return note('Type a place or room name to find.') if @room_query.empty?

        # A place name as filled in, or the one place whose name contains
        # what was typed, before any room title.
        place = area_names.find { |entry| entry[:name].to_s.casecmp?(@room_query) }
        place ||= area_names.select { |entry| entry[:name].to_s.downcase.include?(@room_query.downcase) }.then { |some| some.first if some.size == 1 }
        return show_sheet(place[:image], "Showing #{place[:name]}.") if place

        found = Array(@app.call('action' => 'room_search', 'query' => @room_query))
        return note("No room with #{@room_query} in its title.", error: true) if found.empty?
        return on_go_to_room(found.first[:id], found) if found.size == 1 || found.map { |room| room[:image] }.uniq.size == 1

        @room_matches = found
        note("#{found.size} rooms found; pick one.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # Show the sheet a found room is on, with the view on that room.
      # @param id [Integer] room id
      # @param among [Array<Hash>] the finds it is one of
      # @return [Boolean] whether to re-render
      def on_go_to_room(id, among = room_matches)
        room = among.find { |entry| entry[:id].to_i == id.to_i }
        return note("Room #{id} is not one of the finds.", error: true) unless room

        @room_matches = []
        @map_anchor = room[:id]
        show_sheet(room[:image], "Showing #{room[:title]} (#{room[:id]}).")
      end

      # The room the next fresh draw of the map scrolls to, taken once.
      # @return [Integer, nil]
      def take_map_anchor
        anchor = @map_anchor
        @map_anchor = nil
        anchor
      end

      private

      def show_sheet(image, message)
        @sheet = image.to_s
        @sheet_choices = []
        @map = nil
        @map_frame = nil
        note(message)
      end

      public

      # Whether the creature search is shown on Where to hunt. Off until
      # asked for, like the map.
      # @return [Boolean]
      def creature_search_open?
        return @creature_search_open if @creature_search_for == draft_serial

        list_entries('targets').empty?
      end

      # Show or hide it.
      # @return [Boolean] whether to re-render
      def on_toggle_creature_search
        @creature_search_open = !creature_search_open?
        @creature_search_for = draft_serial
        true
      end

      # The sheets a found creature lives on, when there is more than one
      # to choose from. See #on_find_creature.
      # @return [Array<Hash>] id and name
      def sheet_choices = Array(@sheet_choices)

      # A creature was picked in the search: it is the hunt's creature. The
      # boundaries become the ring around every room it lives in, replacing
      # what was there, since one hunt is one area. A new fence makes it the
      # only target; the same fence adds it to them. The map gets its sheet
      # ready with a left-click setting the start room, and the creatures in
      # the fence are listed under the search to tick. A start room outside
      # the new fence is cleared: it belonged to another hunt.
      # @param name [String] the creature's name
      # @return [Boolean] whether to re-render
      def on_find_creature(name)
        wanted = name.to_s
        return false if wanted.empty?

        fence = @app.call('action' => 'creature_fence', 'name' => wanted)
        rooms = Array(fence[:room_ids])
        return note("No mapped rooms are recorded for #{wanted}.", error: true) if rooms.empty?

        boundaries = Array(fence[:boundary_ids]).map(&:to_s)
        moved = list_entries('hunting_boundaries').sort != boundaries.sort
        write_list('hunting_boundaries', boundaries)
        start = settings['hunting_room_id'].to_s
        on_change('hunting_room_id', '') unless start.empty? || rooms.include?(start.to_i)
        before = list_entries('targets')
        targets = moved ? [wanted] : (before + [wanted]).uniq { |entry| entry.split('(').first.strip.downcase }
        write_list('targets', targets)
        @fence = { serial: draft_serial, rooms: rooms, areas: Array(fence[:areas]), creature: wanted }
        # Open from here on, though the hunt now has a target: the viewer is
        # still choosing.
        @creature_search_open = true
        @creature_search_for = draft_serial
        @creatures_here_for = nil
        @assign_role = 'hunting_room_id'
        @room_query = wanted
        @room_matches = []
        @map_open = true
        @map = nil
        @map_frame = nil
        sheets = Array(fence[:sheets])
        if sheets.size == 1
          @sheet = sheets.first[:id].to_s
          @sheet_choices = []
        else
          @sheet = nil
          @sheet_choices = sheets
        end
        pockets = fence[:pockets].to_i
        where = pockets > 1 ? "its #{pockets} areas" : 'where it lives'
        dropped = moved && !(before - targets).empty? ? " Targets were #{before.join(', ')}." : ''
        note("Hunting #{wanted}: fenced #{where}.#{dropped} Tick what else to hunt below, then choose the start room.")
      rescue StandardError => error
        note(error.message, error: true)
      end

      # A creature's details, for the popup.
      # @param name [String] the creature's name
      # @return [Hash, nil] title and lines, or nil with the reason noted
      def creature_details(name)
        found = @app.call('action' => 'creature_details', 'name' => name.to_s)
        return found unless Array(found[:lines]).empty?

        note("Nothing is recorded about #{name}.", error: true)
        nil
      rescue StandardError => error
        note(error.message, error: true)
        nil
      end

      # Whether the map is drawn. Off until asked for: a sheet is hundreds of
      # layers, and every tab is rendered on every refresh.
      # @return [Boolean]
      def map_open? = @map_open == true

      # Show or hide the map.
      # @return [Boolean] whether to re-render
      def on_toggle_map
        @map_open = !map_open?
        @map = nil unless @map_open
        @map_frame = nil
        true
      end

      # @return [String] the role a left-click on the map assigns
      def assign_role = @assign_role ||= 'hunting_room_id'

      # Choose what a left-click assigns.
      # @param role [String] one of ROLE_LABELS' keys, bar the derived 'hunting'
      # @return [Boolean] whether to re-render
      def on_assign_role(role)
        wanted = role.to_s
        return note("#{wanted} is not a room role.", error: true) unless ROLE_LABELS.key?(wanted) && !%w[hunting creature].include?(wanted)

        @assign_role = wanted
        true
      end

      # Where the drawn surface's top-left sits on the sheet, set by the
      # page when it crops the sheet to the hunt, so a click's coordinates
      # can be turned back into a room.
      attr_accessor :map_origin

      # The crop the map shows, chosen when the map opens or is refitted
      # and kept through every click after: marking a room must not move
      # the view the viewer is marking rooms on.
      attr_accessor :map_frame

      # A click on the map. Left assigns the chosen role; right clears
      # whatever role the room holds, so a room comes out of the hunt without
      # first choosing the role it happens to be in.
      # @param region [String, nil] the clicked region key, "room-<id>"
      # @param button [String] 'primary' or 'secondary'
      # @param point [Hash, nil] where on the surface, when no region was hit
      # @return [Boolean] whether to re-render
      def on_map_click(region, button, point = nil)
        id = region.to_s[/\Aroom-(\d+)\z/, 1]&.to_i
        # A left-click on a room arrives as the region's own event. A client
        # that also reports it as a surface click is reporting the same
        # click twice, and the second would undo the first.
        return false if id && button.to_s != 'secondary' && point

        id ||= room_at(point)
        return false unless id
        return on_assign_room(assign_role, id) unless button.to_s == 'secondary'

        role = role_for(id)
        return note("Room #{id} has no mark to clear.") unless role && role != 'hunting'

        on_clear_room(role, id)
      end

      # Which room covers a point on the surface, which is the sheet's
      # coordinate less the crop's origin.
      # @param point [Hash, nil] x and y on the surface
      # @return [Integer, nil] room id
      def room_at(point)
        return nil unless point.is_a?(Hash)

        x = point[:x] || point['x']
        y = point[:y] || point['y']
        current = map
        return nil if x.nil? || y.nil? || current.nil?

        origin = @map_origin || { x: 0, y: 0 }
        sheet_x = x.to_i + origin[:x].to_i
        sheet_y = y.to_i + origin[:y].to_i
        Array(current[:rooms]).find do |room|
          box = room[:image_coords]
          next false unless box

          sheet_x.between?([box[0], box[2]].min, [box[0], box[2]].max) &&
            sheet_y.between?([box[1], box[3]].min, [box[1], box[3]].max)
        end&.dig(:id)
      end

      # @return [Array<Hash>] errors from the last validation
      def errors = Array(@validation && (@validation[:errors] || @validation['errors']))

      # @return [Array<Hash>] warnings from the last validation
      def warnings = Array(@validation && (@validation[:warnings] || @validation['warnings']))

      # @param key [String] native setting key
      # @return [String, nil] where this key's effective value came from
      def provenance_for(key)
        table = @validation && (@validation[:provenance] || @validation['provenance'])
        table && table[key]
      end

      private

      def recovery_settings
        value = settings['recovery']
        value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
      end

      def ecleanse_settings
        Hash(@app.call('action' => 'ecleanse_settings'))
      rescue StandardError => error
        note("Could not read ecleanse: #{error.message}", error: true)
        {}
      end

      def refresh_boot
        @boot = @app.call('action' => 'bootstrap')
      end

      # Comma text, never an Array: the engine's split/rooms cleaners split a
      # String and stringify an Array, so a list stored as one round-trips as
      # ["[\"a\"", "\"b\"]"].
      def write_list(key, entries)
        on_change(key, entries.empty? ? '' : entries.join(', '))
      end

      def validation_summary
        return 'Checked: no problems found.' if errors.empty? && warnings.empty?

        parts = []
        parts << "#{errors.size} error#{'s' if errors.size != 1}" unless errors.empty?
        parts << "#{warnings.size} warning#{'s' if warnings.size != 1}" unless warnings.empty?
        "Checked: #{parts.join(', ')}."
      end

      def note(message, error: false)
        @status = message
        @status_error = error
        true
      end

      def deep_copy(value)
        case value
        when Hash then value.to_h { |key, item| [key, deep_copy(item)] }
        when Array then value.map { |item| deep_copy(item) }
        when String then value.dup
        else value
        end
      end
    end
  end
end
