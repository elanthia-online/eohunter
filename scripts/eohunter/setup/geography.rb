# frozen_string_literal: true

require_relative 'area_zones'
require_relative 'places'

# Elanthia Online scripts and shared services.
module EO
  # Read-only setup services, independent of the running hunting engine.
  module HunterSetup
    # Resolves native creature habitats against one supplied map snapshot.
    # CreatureTemplate#rooms_by_area silently discards missing UIDs and caches
    # results across map revisions; inspect its underlying #areas instead.
    # The perimeter follows CreatureTemplate#boundary_rooms / BSProfiles.perimeter:
    # every exterior room joined to the footprint by an edge in either direction.
    # Neither movement commands nor executable movement/timing entries are run.
    class Geography
      # Evidence label; static facts never imply a live-world verification.
      VERIFICATION = 'Data-derived; not field-checked'

      # Settings displayed by the persistent profile map, not target suggestions.
      MAP_SETTINGS = %w[hunting_room_id hunting_boundaries rallypoint_room_ids resting_room_id field_rest_room_id].freeze

      # The map settings that hold several rooms, as comma text.
      LIST_MARKERS = %w[hunting_boundaries rallypoint_room_ids].freeze

      # Static adapter for the existing hunting-area walker. Reads exit keys,
      # never invokes a movement expression or a live-world passability check.
      class StaticMap
        # @param rooms [Hash<Integer, Object>] native map snapshot
        def initialize(rooms) = @rooms = rooms

        # @param id [Integer] source room
        # @return [Hash<Integer, nil>] recorded destinations, not guaranteed usable
        def exits_from(id)
          (@rooms[id]&.wayto || {}).each_key.filter_map do |key|
            target = Integer(key.to_s, 10)
            [target, nil] if @rooms.key?(target)
          end.to_h
        end

        # @param id [Integer] source room
        # @return [String, nil] descriptive location only
        def room_location(id)
          room = @rooms[id]
          room.location if room.respond_to?(:location)
        end
      end

      # Binds habitat resolution to caller-supplied native data and revisions.
      # @param templates [Enumerable] native CreatureTemplate instances
      # @param rooms [Enumerable] native Map.list rooms (nil entries allowed)
      # @param uid_resolver [#call] native Map.ids_from_uid-compatible callable
      # @param data_revision [String, nil] caller-supplied creature revision
      # @param map_revision [String, nil] caller-supplied map revision
      # @param catalog [AreaCatalog] validated geographical area definitions
      def initialize(templates:, rooms:, uid_resolver:, data_revision: nil, map_revision: nil, catalog: AreaCatalog.new)
        @templates = templates.to_a
        @rooms = rooms.to_a.compact.to_h { |room| [room.id.to_i, room] }
        @uid_resolver = uid_resolver
        @data_revision = data_revision
        @map_revision = map_revision
        @catalog = catalog
        @map_labels = {}
        @rooms.each_value do |room|
          next unless room.respond_to?(:image) && room.image

          label = Array(room.respond_to?(:tags) ? room.tags : []).find { |tag| tag.to_s.start_with?('meta:mapname:') }
          @map_labels[room.image] = label.delete_prefix('meta:mapname:') if label
        end
      end

      # Lists habitats, retaining exact creature names instead of matching nouns.
      # Level filters include a habitat when any known creature fits the band.
      # Unknown levels are included only when no level filter was requested.
      # @param query [String, nil] case-insensitive habitat or creature search
      # @param min_level [Integer, nil] inclusive lower known creature level
      # @param max_level [Integer, nil] inclusive upper known creature level
      # @return [Array<Hash>] names and native creature metadata
      def areas(query: nil, min_level: nil, max_level: nil)
        habitats = @templates.flat_map { |t| Array(t.areas).map { |a| a[:name].to_s } }.reject(&:empty?).uniq.sort
        parents = @catalog.parents.select do |parent|
          @catalog.for(parent).any? do |entry|
            !(entry[:native_habitat_names] & habitats).empty? || !resolve_uids(entry[:uids])[:room_ids].empty?
          end
        end
        # One name per place. A catalog parent is the researched name for a
        # place the creature templates already name -- "The Hinterwilds"
        # against their "Hinterwilds", which its own records say in
        # native_habitat_names -- and offering both listed one place twice
        # under two spellings, with different subdivisions behind each.
        #
        # The habitat name wins, not the prettier parent: resolving an area
        # goes through the creature templates, so the parent's own spelling
        # resolves to no rooms at all. A parent is offered only where it names
        # a place the templates do not.
        # Only a parent that renames ONE habitat is a duplicate of it. A
        # parent covering several -- "Woodland" over Forest and Meadow -- is a
        # union neither habitat name expresses, and is worth offering beside
        # them.
        renames = parents.select do |parent|
          covered = @catalog.for(parent).flat_map { |entry| Array(entry[:native_habitat_names]) }.map(&:to_s).uniq
          covered.size == 1 && habitats.include?(covered.first)
        end
        names = (habitats + (parents - renames)).uniq.sort
        names.filter_map do |name|
          definitions = AreaZones.for(name, catalog: @catalog)
          candidates = definitions.empty? ? templates_for(name) : definitions.flat_map { |entry| zone_templates(entry, name) }.uniq
          creatures = candidates.sort_by { |t| t.name.to_s }.map { |t| creature(t) }
          text = ([name] + definitions.flat_map { |entry| [entry[:label], *entry[:native_habitat_names]] } + creatures.map { |t| t[:name] }).join(' ').downcase
          next unless query.to_s.empty? || text.include?(query.to_s.downcase)
          if min_level || max_level
            next unless creatures.any? do |t|
              t[:level] && (!min_level || t[:level] >= min_level) && (!max_level || t[:level] <= max_level)
            end
          end
          habitat_uids = templates_for(name).flat_map do |template|
            Array(template.areas).select { |habitat| habitat[:name].to_s == name }.flat_map { |habitat| area_uids(habitat) }
          end.uniq
          places = places_within(candidates, name)
          { name: name, creatures: creatures, verification: VERIFICATION,
            maps: definitions.empty? ? maps_for_uids(habitat_uids) : definitions.flat_map { |entry| zone_maps(entry, name) }.uniq,
            zones: definitions.map { |entry| zone_metadata(entry, name) },
            places: Places.useful?(places) ? places : [],
            place_diagnostic: place_diagnostic(places) }
        end
      end

      # Every creature the installed templates know, flattened to what a
      # player chooses a hunt on. See Creatures.
      # @return [Array<Hash>]
      def creature_catalogue
        @creature_catalogue ||= Creatures.catalogue(@templates)
      end

      # Display/edit existing profile geometry without a creature catalog or
      # replacing custom boundaries. Sheet names are native metadata, not paths
      # opened by this method. All persisted markers remain visible across sheets.
      # @param settings [Hash] raw geometry settings (IDs or UIDs)
      # @param sheet [String, nil] optional additional native map sheet
      # @return [Hash] room diagrams, normalized markers and explicit diagnostics
      def profile_map(settings:, sheet: nil, area: nil)
        raise ArgumentError, 'map settings must be an object' unless settings.is_a?(Hash)

        diagnostics = []
        markers = {}
        refs = []
        MAP_SETTINGS.each do |key|
          raw = settings[key]
          entries = LIST_MARKERS.include?(key) ? (raw.is_a?(Array) ? raw : raw.to_s.split(',')) : [raw]
          ids = entries.filter_map do |entry|
            ref = entry.to_s.strip
            next if ref.empty? || ref == '0'

            mapped = if ref.match?(/\Au\d+\z/i)
                       Array(@uid_resolver.call(ref[1..].to_i)).uniq
                     elsif ref.match?(/\A\d+\z/)
                       [ref.to_i]
                     else
                       []
                     end
            unless mapped.length == 1 && @rooms.key?(mapped.first)
              diagnostics << "#{key}: #{ref} is missing, ambiguous, or not a mapped room. Correct it before editing on the map."
              next
            end
            refs << { ref: ref, id: mapped.first } if key == 'hunting_boundaries'
            mapped.first
          end
          markers[key] = LIST_MARKERS.include?(key) ? ids.uniq.sort : ids.first
        end
        catalog = @rooms.values.filter_map { |room| room.image.to_s if room.respond_to?(:image) && !room.image.to_s.empty? }.uniq.sort
        raise ArgumentError, 'unknown map sheet' if sheet && !sheet.empty? && !catalog.include?(sheet)

        start = markers['hunting_room_id']
        boundaries = markers['hunting_boundaries']
        editable = diagnostics.empty?
        if start && boundaries.include?(start)
          diagnostics << 'The hunting start is also a boundary. Move the start or turn off that boundary.'
        end
        # Named for what it is -- the walker's reachable set -- so it does not
        # shadow the `area` parameter, which is the record being hunted.
        walked = if start && diagnostics.empty?
                   EO::Engine::Wander::Area.new(start: start, boundaries: boundaries).build(StaticMap.new(@rooms))
                 end
        hunting = walked ? walked.rooms : []
        anchors = (markers.values.flatten.compact + hunting).uniq
        sheets = anchors.filter_map do |id|
          room = @rooms[id]
          room.image.to_s if room.respond_to?(:image) && !room.image.to_s.empty?
        end
        sheets << sheet if sheet && !sheet.empty?
        # The sheets the chosen area is drawn on, whatever is marked.
        #
        # The map is a display, not a source of truth: which rooms it shows
        # is a property of the area being hunted, and the markers are only
        # colours painted on top. Deriving the sheet from the markers meant
        # clearing the start room left the walker nothing to walk from, so
        # the hunt's rooms emptied, no sheet was chosen, and the pane went
        # blank until a room was set again.
        sheets.concat(area_sheets(area)) if area
        sheets.uniq!
        visible = (@rooms.values.select { |room| room.respond_to?(:image) && sheets.include?(room.image.to_s) }.map(&:id) + anchors).uniq.sort
        visible_index = visible.to_h { |id| [id, true] }
        edges = footprint_graph(visible)[:edges].select { |from, to| visible_index[from] && visible_index[to] }
        { markers: markers, boundary_refs: refs, rooms: visible.map { |id| room_description(id) }, room_edges: edges,
          hunting_room_ids: hunting, truncated: walked ? walked.too_big? : false,
          sheets: catalog, sheet_labels: @map_labels.slice(*catalog), diagnostics: diagnostics, editable: editable, verification: VERIFICATION }
      end

      # Every name a player might type for a place: each sheet's own name,
      # and each location rooms are drawn under, with the sheet most of
      # that location is drawn on. For filling in as they type.
      # @return [Array<Hash>] name and image, sorted by name
      def area_names
        @area_names ||= begin
          names = @map_labels.map { |image, label| { name: label.to_s, image: image } }
          by_location = Hash.new { |hash, key| hash[key] = Hash.new(0) }
          @rooms.each_value do |room|
            next unless room.respond_to?(:image) && !room.image.to_s.empty? && room.respond_to?(:location)

            location = room.location.to_s
            by_location[location][room.image.to_s] += 1 unless location.empty?
          end
          by_location.each do |location, sheets|
            names << { name: location, image: sheets.max_by { |image, count| [count, image] }.first }
          end
          names.uniq { |entry| entry[:name].downcase }.sort_by { |entry| entry[:name].downcase }
        end
      end

      # The creatures the templates place in any of these rooms, by the
      # rooms' UIDs: what a hunt walking exactly these rooms will meet.
      # @param room_ids [Array<Integer>] mapped room ids; unknown ones are skipped
      # @return [Array<Hash>] name, level and undead, by name
      # The map sheets a creature's rooms are drawn on, from the room uids
      # its templates record. Names are no use here: most template area
      # names match no map area name, but the rooms are the rooms.
      # @param name [String] the creature as the templates name it
      # @return [Array<Hash>] id (the sheet file) and name (its label), sorted
      def creature_sheets(name)
        wanted = name.to_s
        templates = @templates.select { |t| t.name.to_s.casecmp?(wanted) }
        uids = templates.flat_map { |t| Array(t.areas).flat_map { |area| area_uids(area) } }.uniq
        maps_for_uids(uids)
      end

      # The fence for a creature: every room its templates place it in, in
      # every area it lives in, and the ring of rooms just outside them, as
      # Lich's CreatureTemplate#boundary_rooms has it. A creature in three
      # separate pockets gets three rings, one boundary list.
      # @param name [String] the creature as the templates name it
      # @return [Hash] room_ids, boundary_ids, pockets (how many separate
      #   groups of rooms), areas (those groups' room ids) and sheets (as
      #   #creature_sheets)
      def creature_fence(name)
        wanted = name.to_s
        templates = @templates.select { |t| t.name.to_s.casecmp?(wanted) }
        uids = templates.flat_map { |t| Array(t.areas).flat_map { |area| area_uids(area) } }.uniq
        ids = resolve_uids(uids)[:room_ids]
        return { room_ids: [], boundary_ids: [], pockets: 0, areas: [], sheets: [] } if ids.empty?

        # The separate groups of its rooms, largest first: a hunt starts in
        # one and walks only that one.
        areas = components(ids, footprint_graph(ids)[:edges]).sort_by { |area| [-area.size, area.first] }
        { room_ids: ids, boundary_ids: hunt_boundaries(ids, ids), pockets: areas.size, areas: areas,
          sheets: maps_for_uids(uids) }
      end

      # A creature's details for the popup: Creatures.details, then each
      # area it lives in with how many of its rooms are on the map.
      # @param name [String] the creature as the templates name it
      # @return [Hash] title and lines ([style, text]); lines empty when the
      #   creature is unknown
      def creature_details(name)
        template = @templates.find { |t| t.name.to_s.casecmp?(name.to_s) }
        return { title: name.to_s, lines: [] } unless template

        lines = Creatures.details(template)
        areas = Array(template.areas)
        unless areas.empty?
          lines << [:head, 'Lives in']
          areas.each do |area|
            uids = area_uids(area)
            mapped = resolve_uids(uids)[:room_ids].size
            lines << [:line, "#{area[:name]}: #{uids.size} room#{'s' if uids.size != 1} recorded, #{mapped} on the map"]
          end
        end
        level = template.respond_to?(:level) && template.level ? ", level #{template.level}" : ''
        { title: "#{template.name}#{level}", lines: lines }
      end

      def creatures_in_rooms(room_ids)
        ids = Array(room_ids).map { |id| id.to_i }.select { |id| @rooms.key?(id) }
        return [] if ids.empty?

        co_spawns(ids)
      end

      # Rooms drawn on a sheet whose title or location contains the words
      # typed, or whose id or UID is what was typed: for finding the sheet
      # to mark rooms on. Titles are matched first, then locations.
      # @param query [String] part of a title, a location, a room id or uNNNN
      # @param limit [Integer] how many to return
      # @return [Array<Hash>] id, title, location, image and the sheet's label
      def room_search(query:, limit: 40)
        needle = query.to_s.strip.downcase
        return [] if needle.empty?

        drawn = @rooms.values.select { |room| room.respond_to?(:image) && !room.image.to_s.empty? && room.respond_to?(:image_coords) && room.image_coords }
        found = if needle.match?(/\Au\d+\z/)
                  ids = Array(@uid_resolver.call(needle[1..].to_i))
                  drawn.select { |room| ids.include?(room.id) }
                elsif needle.match?(/\A\d+\z/)
                  drawn.select { |room| room.id == needle.to_i }
                else
                  drawn.filter_map do |room|
                    title = Array(room.title).first.to_s
                    location = room.respond_to?(:location) ? room.location.to_s : ''
                    rank = if title.downcase.include?(needle) then 0
                           elsif location.downcase.include?(needle) then 1
                           end
                    [rank, room] if rank
                  end.sort_by { |(rank, room)| [rank, room.id] }.map(&:last)
                end
        found.first(limit).map do |room|
          description = room_description(room.id)
          description.merge(sheet_label: @map_labels[room.image] || room.image)
        end
      end

      # Calculate boundaries for explicit manual membership using native map
      # edges and the same walker as profiles. Never executes movement strings.
      # @param room_ids [Array<Integer>] desired hunting rooms
      # @param start_room_id [Integer] selected hunting start
      # @return [Hash] exact representable footprint or an explicit refusal
      def room_geometry(room_ids:, start_room_id:)
        unless room_ids.is_a?(Array) && !room_ids.empty? && room_ids.all? { |id| id.is_a?(Integer) && @rooms.key?(id) }
          raise ArgumentError, 'Choose mapped hunting rooms first.'
        end
        ids = room_ids.uniq.sort
        raise ArgumentError, 'Choose another starting room before excluding the current start.' unless ids.include?(start_room_id)

        graph = footprint_graph(ids)
        raise ArgumentError, 'This selection has missing map exits; review the area before applying it.' unless graph[:missing_room_ids].empty?

        boundaries = hunt_boundaries(ids, spawn_rooms_among(ids))
        area = EO::Engine::Wander::Area.new(start: start_room_id, boundaries: boundaries).build(StaticMap.new(@rooms))
        unless !area.too_big? && area.rooms.sort == ids
          raise ArgumentError, 'These rooms cannot form one reachable hunt from the selected start. Keep connecting rooms or choose a smaller area.'
        end
        { room_ids: ids, boundary_ids: boundaries, start_room_id: start_room_id, verification: VERIFICATION }
      end

      # Resolves a geographical zone or a legacy creature habitat. Zone member
      # UIDs are independent of target choices, including an empty target list.
      # In an unzoned habitat, selecting creatures retains legacy footprint
      # filtering. Explicit empty room subsets remain empty. Invalid selections raise rather than silently
      # broadening the footprint. Connectivity is weak graph connectivity: even a
      # single component need not be reachable from every possible starting room.
      # Callers must compare the chosen entrance against Hunter's directed area
      # builder before offering a ready-to-launch profile.
      # @param area [String] exact catalog parent or native habitat name
      # @param creature_names [Array<String>, nil] target choices, or legacy habitat subset
      # @param room_ids [Array<Integer>, nil] further restriction of resolved rooms
      # @param zone [String, nil] explicit named subarea, required for subdivided suggestions
      # @param map_image [String, nil] selected classic map context for an unpartitioned habitat
      # @param added_room_ids [Array<Integer>, nil] explicit manual additions on the selected map sheet
      # @return [Hash] JSON-compatible footprint, perimeter, co-spawns and evidence
      # @raise [ArgumentError] unknown habitat, creature, or room subset
      # How several area names arrive as one string, where they do.
      SEPARATOR = /\s*\|\s*/

      def resolve(area:, creature_names: nil, room_ids: nil, zone: nil, map_image: nil, added_room_ids: nil)
        raise ArgumentError, 'creature_names must be an array' unless creature_names.nil? || creature_names.is_a?(Array)
        raise ArgumentError, 'room_ids must be an array' unless room_ids.nil? || room_ids.is_a?(Array)
        raise ArgumentError, 'added_room_ids must be an array' unless added_room_ids.nil? || added_room_ids.is_a?(Array)
        # Several names resolve as one hunting ground.
        #
        # The same ground is catalogued under more than one name -- "The
        # Hinterwilds" beside "Hinterwilds" -- and a hunt that spans the split
        # needs both. Unioned at the template level rather than by merging two
        # results, so the footprint is walked once and its boundaries are the
        # edges of the whole of it: concatenating two resolves would call the
        # seam between them a boundary and stop the hunt crossing it.
        names = Array(area).flat_map { |entry| entry.to_s.split(SEPARATOR) }.map(&:strip).reject(&:empty?)
        raise ArgumentError, 'area must name a habitat' if names.empty?

        area = names.first
        selected = names.flat_map { |name| templates_for(name) }.uniq { |t| t.name.to_s }.sort_by { |t| t.name.to_s }
        zones = names.flat_map { |name| AreaZones.for(name, catalog: @catalog) }.uniq
        raise ArgumentError, "Unknown habitat: #{names.join(', ')}" if selected.empty? && zones.empty?
        chosen = zones.find { |entry| entry[:id] == zone } unless zone.to_s.empty?
        raise ArgumentError, "Unknown subarea for #{area}: #{zone}" if !zone.to_s.empty? && !chosen
        if !zones.empty? && !chosen && (!creature_names.nil? || !room_ids.nil?)
          raise ArgumentError, 'Choose a named subarea before suggesting hunting rooms.'
        end
        selected = zone_templates(chosen, area.to_s) if chosen
        visitors = AreaZones.visitors(area.to_s, chosen && chosen[:id]).map do |entry|
          template = @templates.find { |candidate| candidate.name.to_s == entry[:name] }
          entry.merge(template ? creature(template) : { level: nil, undead: nil })
        end
        selected_names = (selected.map { |template| template.name.to_s } + visitors.map { |entry| entry[:name] }).uniq
        unless creature_names.nil?
          names = Array(creature_names).map(&:to_s)
          unknown = names - selected_names
          raise ArgumentError, "Creatures not in habitat: #{unknown.join(', ')}" unless unknown.empty?
          selected = selected.select { |t| names.include?(t.name.to_s) }
          selected_names &= names
        end
        uids = selected.flat_map do |template|
          Array(template.areas).select { |a| a[:name].to_s == area.to_s }.flat_map { |a| area_uids(a) }
        end.uniq.sort
        uids = zone_uids(chosen, area.to_s) if chosen
        mapping = resolve_uids(uids)
        ids = mapping[:room_ids]
        # The rooms the creatures are actually catalogued in, kept aside
        # before the footprint grows past them. A hunt should start in one:
        # spawning stops in many areas while nobody is standing in them, so a
        # start room outside the creatures' own rooms means crossing back in
        # from somewhere that has been quietly emptying.
        spawn_ids = ids.dup
        if map_image && !map_image.empty?
          unless @rooms.values.any? { |room| room.respond_to?(:image) && room.image == map_image }
            raise ArgumentError, 'Unknown hunting map'
          end
          if chosen
            unless zone_maps(chosen, area.to_s).any? { |map| map[:id] == map_image }
              raise ArgumentError, 'Subarea is not on the selected hunting map'
            end
            # An explicit UID-defined zone also retains its unpositioned rooms.
          else
            ids = ids.select { |id| @rooms[id].respond_to?(:image) && @rooms[id].image == map_image }
          end
        end
        additions = Array(added_room_ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
        unless additions.empty?
          valid = map_image && !map_image.empty? && additions.all? do |id|
            room = @rooms[id]
            room && room.respond_to?(:image) && room.image == map_image
          end
          raise ArgumentError, 'Manual additions must be rooms on the selected hunting map' unless valid
          raise ArgumentError, 'Choose a named subarea before editing hunting rooms.' if !zones.empty? && !chosen
          ids = (ids + additions).uniq.sort
        end
        unless room_ids.nil?
          subset = Array(room_ids).map { |id| Integer(id.to_s, 10) }.uniq.sort
          # A room the catalogue does not place in the habitat is still part
          # of it when a place the habitat's own creatures live in reaches it:
          # a village's smithy carries no creature UID, and neither do the
          # paths between its spawn points, but they are the village all the
          # same. Anything outside such a place is still refused, which is
          # what stops an unrelated room being smuggled into a footprint.
          outside = subset - ids - place_rooms_within(ids, area.to_s)
          raise ArgumentError, "Rooms not in resolved habitat: #{outside.join(', ')}" unless outside.empty?
          ids = subset
        end
        graph = footprint_graph(ids)
        boundaries = (graph[:incoming] + graph[:outgoing]).uniq.sort
        portions = components(ids, graph[:edges])
        complete = !ids.empty? && mapping[:unresolved_uids].empty? && mapping[:missing_room_ids].empty? &&
                   mapping[:ambiguous_uids].empty? && graph[:missing_room_ids].empty?
        residents = co_spawns(ids)
        {
          area: area.to_s, selected_creature_names: selected_names.sort,
          map_image: map_image,
          zones: zones.map { |entry| zone_metadata(entry, area.to_s) }, zone_id: chosen && chosen[:id], zone_label: chosen && chosen[:label],
          zone_metadata: chosen && zone_metadata(chosen, area.to_s), added_room_ids: additions,
          zone_selection_required: !zones.empty? && !chosen,
          room_ids: ids, boundary_ids: boundaries, spawn_room_ids: (spawn_ids & ids).sort,
          rooms: ids.map { |id| room_description(id) },
          context_rooms: @rooms.values.select { |room| map_image && room.respond_to?(:image) && room.image == map_image }.map { |room| room_description(room.id.to_i) },
          boundary_rooms: boundaries.filter_map { |id| room_description(id) if @rooms.key?(id) },
          context_edges: graph[:edges],
          room_edges: graph[:edges].select { |source, target| ids.include?(source) && ids.include?(target) },
          incoming_boundary_ids: graph[:incoming], outgoing_boundary_ids: graph[:outgoing],
          components: portions, opaque_edges: graph[:opaque_edges],
          creatures: residents,
          visitors: visitors.reject { |entry| residents.any? { |resident| resident[:name] == entry[:name] } },
          coverage: { complete: complete, uid_count: uids.length, room_count: ids.length,
                      unresolved_uids: mapping[:unresolved_uids], ambiguous_uids: mapping[:ambiguous_uids],
                      missing_room_ids: mapping[:missing_room_ids], missing_edge_room_ids: graph[:missing_room_ids] },
          diagnostics: diagnostics(ids, mapping, graph, portions) + catalog_diagnostics(chosen) +
            (additions.empty? ? [] : [{ code: 'manual_area_edit', message: 'Room membership was manually extended; review the resulting area and boundaries.' }]),
          data_revision: @data_revision, map_revision: @map_revision, verification: VERIFICATION
        }
      end

      private

      def zone_uids(entry, parent)
        return entry[:uids] unless entry[:uids].is_a?(Range)

        # Legacy Rift ranges are selectors over known native UIDs, not evidence
        # that every number in an interval is an existing room.
        native = templates_for(parent).flat_map do |template|
          Array(template.areas).select { |habitat| habitat[:name].to_s == parent }.flat_map { |habitat| area_uids(habitat) }
        end
        mapped = @rooms.values.flat_map { |room| Array(room.uid) }.compact.map { |uid| Integer(uid.to_s, 10) }
        (native + mapped).uniq.select { |uid| entry[:uids].cover?(uid) }.sort
      end

      def zone_templates(entry, parent)
        aliases = entry.fetch(:native_habitat_names, [parent])
        members = zone_uids(entry, parent).to_h { |uid| [uid, true] }
        @templates.select do |template|
          Array(template.areas).any? do |habitat|
            aliases.include?(habitat[:name].to_s) && area_uids(habitat).any? { |uid| members[uid] }
          end
        end.sort_by { |template| template.name.to_s }
      end

      def zone_maps(entry, parent)
        names = Array(entry[:map_sheets])
        (maps_for_uids(zone_uids(entry, parent)) + names.map { |name| { id: name, name: @map_labels.fetch(name, name) } }).uniq.sort_by { |map| map[:id] }
      end

      def zone_metadata(entry, parent)
        entry.reject { |key, _| key == :uids }.merge(maps: zone_maps(entry, parent), diagnostics: catalog_diagnostics(entry))
      end

      def catalog_diagnostics(entry)
        return [] unless entry && entry[:status]

        result = []
        if entry[:status] == 'draft'
          result << { code: 'catalog_draft', message: 'Research draft: review and edit this geographical baseline before applying it. It is not field-checked.' }
        end
        check = entry[:static_check][:result] || entry[:static_check]['result']
        unless check == 'pass'
          result << { code: 'catalog_static_check', message: "The catalog static check is #{check}; membership or reachability remains incomplete." }
        end
        result
      end

      # The sheet names an area record carries, however it names them.
      # @param area [Hash, String, Array, nil]
      # @return [Array<String>]
      def area_sheets(area)
        entries = case area
                  when Hash  then Array(area[:maps] || area['maps'])
                  when Array then area
                  else [area]
                  end
        entries.filter_map do |entry|
          name = entry.is_a?(Hash) ? (entry[:id] || entry['id']) : entry
          name.to_s unless name.to_s.empty?
        end.uniq
      end

      def maps_for_uids(uids)
        ids = resolve_uids(uids)[:room_ids]
        ids.filter_map do |id|
          room = @rooms[id]
          room.image if room.respond_to?(:image) && !room.image.to_s.empty?
        end.uniq.sort.map { |name| { id: name, name: @map_labels.fetch(name, name) } }
      end

      def room_description(id)
        room = @rooms.fetch(id)
        box = room.respond_to?(:image_coords) ? room.image_coords : nil
        coords = if box.is_a?(Array) && box.length == 4 && box.all? { |value| value.is_a?(Numeric) && value.finite? }
                   [(box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0]
                 end
        title = room.respond_to?(:title) ? Array(room.title).first : nil
        { id: id, title: title.to_s.empty? ? "Room #{id}" : title.to_s,
          location: room.respond_to?(:location) ? room.location : nil,
          image: room.respond_to?(:image) ? room.image : nil, coords: coords, image_coords: coords ? box : nil }
      end

      # Every room the habitat's own places cover, spawn room or not.
      #
      # This is what makes a village's connective rooms acceptable in a
      # footprint: they carry no creature UID, so the catalogue does not place
      # them in the habitat, but the place built from the creatures' own spawn
      # rooms reaches them.
      def place_rooms_within(spawn_ids, area)
        titles = room_titles
        creatures = [{ name: area, room_ids: spawn_ids }]
        Places.within(creatures, titles, neighbours: method(:linked_rooms))
              .flat_map { |place| place[:room_ids] }.uniq
      rescue StandardError
        []
      end

      # The named places inside a habitat, from the rooms its creatures
      # actually spawn in.
      #
      # A template records the habitat only, so every gigas says
      # "Hinterwilds" while their rooms sit in four different villages. The
      # room titles carry that split already, so it is read rather than
      # curated -- see Places.
      def places_within(templates, area)
        # Every name this area goes by. A catalog parent is the researched
        # name for a place the creature templates call something else -- "The
        # Hinterwilds" against their "Hinterwilds" -- and a template's own
        # habitat is the only thing tying a creature to a room, so matching
        # the parent's spelling alone found no rooms and no places at all.
        wanted = ([area.to_s] + habitat_names_for(area.to_s)).uniq
        creatures = Array(templates).map do |template|
          uids = Array(template.areas)
                 .select { |habitat| wanted.include?(habitat[:name].to_s) }
                 .flat_map { |habitat| area_uids(habitat) }
          { name: template.name.to_s, room_ids: resolve_uids(uids)[:room_ids] }
        end
        Places.within(creatures, room_titles, neighbours: method(:linked_rooms))
      rescue StandardError => e
        # Reported rather than swallowed. A bare `rescue => []` here means a
        # habitat with no places looks exactly like a habitat whose place
        # derivation raised, and the picker is empty either way with nothing
        # said about which happened.
        @place_errors = "#{e.class}: #{e.message}"
        []
      end

      # @return [String, nil] why place derivation failed, if it did
      attr_reader :place_errors

      # Why an area offers no parts to choose between.
      #
      # An empty picker has three quite different causes -- the derivation
      # raised, it found nothing, or it found exactly one place and one is
      # not a choice -- and they were indistinguishable from outside.
      # @param places [Array<Hash>]
      # @return [String, nil]
      def place_diagnostic(places)
        return "parts could not be worked out (#{@place_errors})" if @place_errors
        return nil if Places.useful?(places)
        return 'this area is not divided into parts' if places.empty?

        "this area is all one part (#{places.first[:name]})"
      end

      # The creature-template habitat names a catalog parent covers.
      #
      # Empty for an area that is itself a habitat name, which is the common
      # case: only a researched parent renames anything.
      def habitat_names_for(area)
        @catalog.for(area).flat_map { |entry| Array(entry[:native_habitat_names]) }.map(&:to_s).uniq
      rescue StandardError
        []
      end

      # Which rooms a room links to, in both directions.
      #
      # Built once and cached: Places walks it per habitat, and rebuilding the
      # reverse links for each would be the whole map every time.
      def linked_rooms(id)
        @linked_rooms ||= begin
          index = Hash.new { |hash, key| hash[key] = [] }
          @rooms.each do |source, room|
            (room.wayto || {}).each_key do |destination|
              target = Integer(destination.to_s, 10)
              index[source] << target
              index[target] << source
            rescue ArgumentError, TypeError
              next
            end
          end
          index
        end
        @linked_rooms[id]
      end

      # Every room's title, since Places walks through rooms the creatures do
      # not spawn in.
      #
      # Passing only the spawn rooms' titles was a real bug: the walk crosses
      # a village's smithy and longhouses to reach the next spawn point, and
      # with no title for those it could not tell whether they belonged, so
      # every place collapsed to the couple of rooms that happened to touch.
      def room_titles
        @room_titles ||= @rooms.to_h do |id, room|
          title = room.respond_to?(:title) ? Array(room.title).first : nil
          [id, title.to_s]
        end
      end

      def templates_for(name)
        @templates.select { |t| Array(t.areas).any? { |a| a[:name].to_s == name } }.sort_by { |t| t.name.to_s }
      end

      def creature(template)
        { name: template.name.to_s, level: template.level,
          undead: template.respond_to?(:undead) ? template.undead : nil,
          # The bestiary's boss classification: nil, "pack", "miniboss" or
          # "boss". A boss-type creature is one that can carry boons.
          boss_type: template.respond_to?(:boss_type) ? template.boss_type : nil,
          boss: template.respond_to?(:boss) ? template.boss == true : false }
      end

      def area_uids(area)
        Array(area[:uids]).flat_map { |entry| entry.is_a?(Range) ? entry.to_a : [entry] }.map { |uid| Integer(uid.to_s, 10) }
      end

      def resolve_uids(uids)
        result = { room_ids: [], unresolved_uids: [], ambiguous_uids: {}, missing_room_ids: [] }
        uids.each do |uid|
          mapped = Array(@uid_resolver.call(uid)).map { |id| Integer(id.to_s, 10) }.uniq.sort
          known, missing = mapped.partition { |id| @rooms.key?(id) }
          result[:unresolved_uids] << uid if known.empty?
          result[:ambiguous_uids][uid] = mapped if mapped.length > 1
          result[:room_ids].concat(known)
          result[:missing_room_ids].concat(missing)
        end
        result[:room_ids] = result[:room_ids].uniq.sort
        result[:missing_room_ids] = result[:missing_room_ids].uniq.sort
        result
      end

      # The boundaries worth naming: those that edge a room creatures spawn in.
      #
      # A boundary stops the hunt wandering out of the creatures' rooms, so it
      # belongs on the edge of them. Every room adjacent to the footprint was
      # named one, and a footprint includes the connectors the walker pulled
      # in to join spawn points -- so a room two steps past the nearest spawn,
      # across an arch nothing lives beyond, was called a boundary while the
      # room that actually needed blocking was not.
      #
      # Falls back to all of them when nothing is known to spawn: an area with
      # no spawn rooms recorded is better bounded loosely than not at all.
      #
      # @param boundaries [Array<Integer>] every room adjacent to the footprint
      # @param spawns [Array<Integer>] rooms the creatures are catalogued in
      # @return [Array<Integer>]
      def spawn_edged(boundaries, spawns)
        return boundaries if spawns.nil? || spawns.empty?

        wanted = spawns.to_h { |id| [id, true] }
        kept = boundaries.select { |id| adjacent_ids(id).any? { |other| wanted[other] } }
        kept.empty? ? boundaries : kept
      end

      # Which of these rooms any creature is catalogued in.
      #
      # For a manual selection, where no habitat was resolved to say so: a
      # room is a spawn room when some template's own UIDs reach it.
      # @param ids [Array<Integer>] the footprint
      # @return [Array<Integer>]
      def spawn_rooms_among(ids)
        wanted = ids.to_h { |id| [id, true] }
        @templates.flat_map { |template| Array(template.areas).flat_map { |area| area_uids(area) } }
                  .uniq
                  .flat_map { |uid| Array(@uid_resolver.call(uid)).map { |id| Integer(id.to_s, 10) } }
                  .uniq.select { |id| wanted[id] }
      rescue StandardError
        []
      end

      # Every room one step from this one, in either direction.
      # @param id [Integer] room id
      # @return [Array<Integer>]
      def adjacent_ids(id)
        room = @rooms[id]
        out = room ? Array(room.wayto&.keys).map { |key| Integer(key.to_s, 10) } : []
        inbound = @rooms.each_with_object([]) do |(source, other), found|
          found << source if Array(other.wayto&.keys).map { |key| Integer(key.to_s, 10) }.include?(id)
        end
        (out + inbound).uniq
      rescue StandardError
        []
      end

      # Where the hunt should be stopped.
      #
      # What the creature rooms open onto that is not the hunt, which is
      # Lich's CreatureTemplate#boundary_rooms rule and what a player means by
      # the edge of a hunting ground.
      #
      # It is one rule only because the footprint is the creature rooms and
      # the bridges between them -- see connected_within. Ringing the place as
      # a player sees it instead, the arch out included, put the boundary a
      # room past the outermost connector: a hunt reported itself bounded
      # beyond an arch nothing lives on the far side of, and the walker could
      # stand in the arch, where nothing spawns and so nothing respawns.
      #
      # @param ids [Array<Integer>] the footprint
      # @param spawns [Array<Integer>] the rooms creatures are catalogued in
      # @return [Array<Integer>] rooms the hunt must not cross into
      # The creature rooms plus whatever of the place joins them up.
      #
      # A village's two streets are joined through its smithy, which carries
      # no creature UID: keeping only the creature rooms would leave the hunt
      # two halves it cannot walk between.
      #
      # Two, not one: a room joining TWO rooms already in the hunt is a bridge
      # between them and belongs to it, while a room touching only one is a
      # way out -- the arch, the path to the river. Admitting those on a
      # single touch put the arch inside the hunt, which pushed its boundary a
      # room further out and let the walker stand where nothing spawns.
      #
      # @param spawns [Array<Integer>] the creature rooms
      # @param allowed [Array<Integer>] the place's own rooms, the walk's limit
      # @return [Array<Integer>]
      def connected_within(spawns, allowed)
        return spawns if spawns.empty?

        reached = spawns.to_h { |id| [id, true] }
        loop do
          joining = allowed.reject { |id| reached[id] }
                           .select { |id| exits_beyond([id]).count { |dest| reached[dest] } >= 2 }
          break if joining.empty?

          joining.each { |id| reached[id] = true }
        end
        reached.keys.sort
      end

      def hunt_boundaries(ids, spawns)
        inside = ids.to_h { |id| [id, true] }
        ringed = spawns & ids
        ringed = ids if ringed.empty?
        exits_beyond(ringed).reject { |id| inside[id] }.uniq.sort
      end

      # Every room these rooms open onto, the hunt's own included.
      #
      # Forward edges only: a boundary stops the walker, the walker travels
      # forward edges, and a room that can only enter the hunt is never
      # somewhere it can step into. Checked exhaustively -- the reverse pass
      # in CreatureTemplate#boundary_rooms adds only such entrance-only rooms.
      # @param ids [Array<Integer>] rooms to look out from
      # @return [Array<Integer>]
      def exits_beyond(ids)
        ids.flat_map { |id| Array(@rooms[id]&.wayto&.keys).map { |key| Integer(key.to_s, 10) } }.uniq
      rescue StandardError
        []
      end

      def footprint_graph(ids)
        inside = ids.to_h { |id| [id, true] }
        result = { incoming: [], outgoing: [], edges: [], opaque_edges: [], missing_room_ids: [] }
        @rooms.each do |source, room|
          (room.wayto || {}).each do |destination, movement|
            target = Integer(destination.to_s, 10)
            next unless inside[source] || inside[target]
            result[:edges] << [source, target]
            result[:outgoing] << target if inside[source] && !inside[target]
            result[:incoming] << source if !inside[source] && inside[target]
            result[:missing_room_ids] << target unless @rooms.key?(target)
            timing = room.respond_to?(:timeto) ? (room.timeto || {})[destination] : nil
            if !movement.instance_of?(String) || timing.respond_to?(:call)
              result[:opaque_edges] << { from: source, to: target }
            end
          end
        end
        [:incoming, :outgoing, :missing_room_ids].each { |key| result[key] = result[key].uniq.sort }
        result
      end

      def components(ids, edges)
        adjacency = ids.to_h { |id| [id, []] }
        edges.each do |source, target|
          next unless adjacency.key?(source) && adjacency.key?(target)
          adjacency[source] << target
          adjacency[target] << source
        end
        unseen = ids.to_h { |id| [id, true] }
        result = []
        until unseen.empty?
          queue = [unseen.keys.first]
          portion = []
          until queue.empty?
            id = queue.pop
            next unless unseen.delete(id)
            portion << id
            queue.concat(adjacency[id])
          end
          result << portion.sort
        end
        result
      end

      def co_spawns(ids)
        uids = ids.flat_map { |id| Array(@rooms.fetch(id).uid) }.compact.map { |uid| Integer(uid.to_s, 10) }.uniq
        @templates.select { |t| uids.any? { |uid| t.found_at_uid?(uid) } }.sort_by { |t| t.name.to_s }.map { |t| creature(t) }
      end

      def diagnostics(ids, mapping, graph, portions)
        result = [{ code: 'unverified', message: VERIFICATION },
                  { code: 'static_map', message: 'Mapped links do not establish current access, traversability, or exhaustive creature spawns.' }]
        if ids.length > 1
          arrivals = graph[:edges].filter_map { |from, to| to if from != to && ids.include?(from) && ids.include?(to) }
          no_entry = ids - arrivals
          unless no_entry.empty?
            result << { code: 'no_mapped_entry', message: "Rooms #{no_entry.join(', ')} have no mapped entrance from other selected rooms. Review them before applying; they may not be reachable from your chosen start." }
          end
        end
        result << { code: 'empty_footprint', message: 'No mapped rooms selected; this is not unrestricted hunting permission.' } if ids.empty?
        result << { code: 'unresolved_uids', message: 'Some habitat UIDs have no room in the supplied map.' } unless mapping[:unresolved_uids].empty?
        result << { code: 'ambiguous_uids', message: 'Some habitat UIDs map to multiple room IDs; all candidates are shown.' } unless mapping[:ambiguous_uids].empty?
        result << { code: 'missing_rooms', message: 'Some mapped room or exit IDs are absent from the supplied map.' } unless (mapping[:missing_room_ids] + graph[:missing_room_ids]).empty?
        result << { code: 'disconnected', message: 'The footprint has disconnected portions; one hunt entrance cannot cover them all.' } if portions.length > 1
        result << { code: 'opaque_exits', message: 'Executable or unknown map exits were not evaluated; their traversal is unknown.' } unless graph[:opaque_edges].empty?
        result << { code: 'revision_unknown', message: 'Creature or map revision is unavailable.' } unless @data_revision && @map_revision
        result
      end
    end
  end
end
