# frozen_string_literal: true

module EO
  module HunterSetup
    # What the page's controls do: each event is handed here by name, the
    # editor's +on_*+ method is called, and the page is refreshed when the
    # editor says its state changed.
    #
    # Nothing here reaches into Lich either. Refreshing the page and asking
    # before edits are thrown away are callables the launcher supplies, so
    # the wiring from control to editor can be exercised in a spec with a
    # fake event.
    class Session
      # Every handler the page may bind. Declared so a spec can check that
      # what the page binds is handled, and a handler the page expects and
      # this does not supply fails at the first click, as ArgumentError.
      HANDLERS = %i[
        rename load set_default copy_legacy new validate save revert select_page
        search change list_set_all test_condition
        set_active request_delete
        toggle_map sheet find_room go_to_room assign_role map_click map_wheel map_zoom map_reset_zoom room_geometry
        show_page hunt_creature hunt_all toggle_boons toggle_boon
        hunt_filter toggle_creature_search find_creature creature_sort
        recovery_set import_ecleanse toggle_fold
      ].freeze

      # What Test now said about each condition, by setting key.
      attr_reader :editor, :test_results

      # @param editor [Editor] the editing session
      # @param evaluate [#call, nil] runs a Ruby condition where the hunt
      #   would, for Test now; nil shows the button doing nothing useful
      # @param refresh [#call] redraws the page
      # @param confirm [#call] called with what is about to happen and a
      #   block; calls the block with true once the viewer agrees to lose
      #   unsaved edits, or with false when they keep editing
      # @param details [#call] shows a creature's details, given its title
      #   and lines
      # @param ask [#call] asks a yes-or-no question in a dialog, given the
      #   title, the question and the yes button's label, and calls the
      #   block with the answer
      # @param set_view [#call] sets a viewer-scoped property of a rendered
      #   component for the viewer being answered, given its ID, the
      #   property and the value
      def initialize(editor:, evaluate: nil, refresh: nil, confirm: nil, details: nil, ask: nil, set_view: nil)
        @editor = editor
        @evaluate = evaluate
        @refresh = refresh || proc {}
        @confirm = confirm || proc { |_what, &change| change.call(true) }
        @details = details || proc { |_found| nil }
        @ask = ask || proc { |**_question, &answer| answer.call(true) }
        @set_view = set_view || proc { |_cid, _property, _value| nil }
        @test_results = {}
      end

      # Handle one event from the page.
      #
      # @param name [Symbol] one of HANDLERS
      # @param event [#payload] what the browser sent; +payload+ is a Hash
      #   with +:value+ for inputs and +:row+ for tables
      # @param args [Array] what the page curried in: a setting key, a step
      #   id, a creature name
      # @return [void]
      # @raise [ArgumentError] for a name the page binds and this does not handle
      def call(name, event, *args)
        payload = event.respond_to?(:payload) ? (event.payload || {}) : {}
        value = payload[:value]
        case name
        when :rename then apply(editor.on_rename(value))
        when :load then open_hunt(value)
        when :set_default then apply(editor.on_set_active(value == true ? args[0] : nil))
        when :copy_legacy then import(value)
        when :new then guarded('Start a new hunt') { editor.on_new }
        when :validate then apply(editor.on_validate)
        when :save then apply(editor.on_save)
        when :revert then guarded('Revert') { editor.on_revert }
        when :select_page then apply(editor.on_select_page(payload[:index]))
        when :search then apply(editor.on_search(value))
        when :change then change(args[0], value)
        when :list_set_all then apply(editor.on_list_set_all(args[0], value.to_s.split(/[,\n]/).map(&:strip)))
        when :test_condition then test(args[0])
        when :set_active then apply(editor.on_set_active(blank(value)))
        when :request_delete then delete(args[0])
        when :toggle_map then apply(editor.on_toggle_map)
        when :show_page then show_page(args[0])
        when :toggle_fold then apply(editor.on_toggle_fold(args[0]))
        when :recovery_set then apply(editor.on_recovery_set(args[0], value))
        when :import_ecleanse then apply(editor.on_import_ecleanse)
        when :hunt_creature then apply(editor.on_hunt_creature(args[0], value == true))
        when :hunt_all then apply(editor.on_hunt_all(args[0]))
        when :toggle_boons then apply(editor.on_toggle_boons(args[0]))
        when :toggle_boon then apply(editor.on_toggle_boon(args[0], args[1], value == true))
        when :sheet then apply(editor.on_sheet(value))
        when :find_room then find_room(value)
        when :go_to_room then apply(editor.on_go_to_room(value.to_i)) unless value.to_s.empty?
        when :assign_role then apply(editor.on_assign_role(value))
        # A left-click on a room arrives as the region's own event. A
        # right-click arrives through the surface, with the region named
        # when one was under the pointer and the coordinates otherwise.
        when :map_click
          apply(editor.on_map_click(payload[:region], payload[:button], { x: payload[:x], y: payload[:y] }))
        when :map_wheel then apply(editor.on_map_zoom(payload[:direction]))
        when :map_zoom then apply(editor.on_map_zoom(args[0]))
        when :map_reset_zoom then apply(editor.on_map_reset_zoom)
        when :room_geometry then apply(editor.on_room_geometry(args[0], args[1]))
        when :hunt_filter then apply(editor.on_hunt_filter(args[0], hunt_value(args[0], value)))
        when :toggle_creature_search then apply(editor.on_toggle_creature_search)
        when :creature_sort then apply(editor.on_creature_sort(value))
        when :find_creature
          names = editor.creature_matches.map { |creature| creature[:name].to_s }
          picked = Page.row_name('m', payload[:row], names)
          # The Details cell opens the popup; any other cell fences the
          # creature and goes to the map.
          return apply(editor.on_find_creature(picked)) unless payload[:column].to_s == 'details'

          found = editor.creature_details(picked)
          found ? @details.call(found) : apply(true)
        else raise ArgumentError, "the setup page has no handler named #{name}"
        end
      end

      private

      # Redraw when the editor says to.
      def apply(changed)
        @refresh.call if changed
        changed
      end

      # Run a change that would discard edits, once the viewer agrees. A
      # refusal still redraws, so a picker that was moved snaps back to what
      # is actually open rather than naming a hunt that was never loaded.
      # Ask in a dialog before deleting a hunt, naming what else uses it.
      def delete(name)
        return apply(true) unless editor.on_request_delete(name) && editor.pending_delete

        dependents = Array(editor.pending_delete[:dependents] || editor.pending_delete['dependents'])
        question = "Delete #{name}? A backup is kept." + (dependents.empty? ? '' : " Also named by: #{dependents.join(', ')}.")
        @ask.call(title: 'Delete hunt', body: question, yes: 'Delete') do |agreed|
          apply(agreed ? editor.on_confirm_delete : editor.on_cancel_delete)
        end
      end

      # Move the viewer to another page. The selected tab is the viewer's
      # own, so it is set for them as well as in the draft.
      def show_page(id)
        moved = editor.on_show_page(id)
        @set_view.call(editor.tabs_cid, :selected, editor.page_index) if moved && editor.tabs_cid
        apply(moved)
      end

      def guarded(what, &change)
        return apply(change.call) unless editor.dirty?

        @confirm.call(what) { |agreed| agreed ? apply(change.call) : @refresh.call }
      end

      def open_hunt(name)
        return if name.to_s.empty?

        guarded('Open another hunt') { editor.on_load(name) }
      end

      def import(name)
        return if name.to_s.empty?

        guarded('Open a Bigshot profile') { editor.on_copy_legacy(name) }
      end

      # A control's value as the setting's value. A checkbox sends a boolean,
      # which is kept as one; everything else is text that Form parses.
      def change(key, value)
        return apply(editor.on_change(key, value)) if value == true || value == false

        field = editor.fields.find { |entry| entry['key'] == key }
        apply(editor.on_change(key, field ? Form.parse(field, value.to_s) : value.to_s))
      end

      # How long typing in the finder has to pause before it is searched.
      FIND_DELAY = 0.5

      # The finder sends every keystroke. A place picked from its list is
      # searched at once; anything else waits for the typing to pause, and
      # only the last thing typed is searched.
      def find_room(text)
        editor.room_query = text
        @find_sequence = (@find_sequence || 0) + 1
        sequence = @find_sequence
        return apply(editor.on_find_room(text)) if editor.area_names.any? { |entry| entry[:name].to_s == text.to_s }

        Thread.new do
          sleep FIND_DELAY
          apply(editor.on_find_room(text)) if sequence == @find_sequence
        end
      end

      # Run a condition where the hunt would, off this thread, and show what
      # it said when it finishes.
      def test(key)
        unless @evaluate
          @test_results[key] = 'Test now is not available here.'
          return apply(true)
        end

        code = editor.settings[key].to_s
        @test_results[key] = 'Running...'
        apply(true)
        Thread.new do
          @test_results[key] = Page.test_condition(code, @evaluate)
          apply(true)
        end
      end

      def blank(value)
        value.to_s.empty? ? nil : value.to_s
      end

      # A creature search field's value as the finder takes it: the level
      # bounds are whole numbers, a yes-or-no filter is true or false, a
      # list filter is a list of one, the name is text. Blank clears it.
      def hunt_value(field, value)
        return nil if value.nil? || value.to_s.strip.empty?

        case field.to_sym
        when :low, :high then value.to_i
        when :undead, :boss, :bcs, *Creatures::SPARSE then value.to_s == 'yes'
        when :families, :types, :classes then [value.to_s]
        else value.to_s
        end
      end
    end
  end
end
