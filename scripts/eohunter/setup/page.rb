# frozen_string_literal: true

require 'digest'

module EO
  module HunterSetup
    # The editor, drawn through Lich's WebUI.
    #
    # A render function over Editor: the whole page is rebuilt from the
    # editor's state on every refresh, and every control hands what it holds
    # to the Session, which calls the editor's +on_*+ method and refreshes.
    # Which control a setting gets, and how its text becomes a value, is
    # Form's business.
    #
    # Nothing here reaches into Lich. The builder is Lich's TreeBuilder in
    # the game and a recording stand-in in the specs, so the page can be
    # rendered and its wiring checked without a browser.
    #
    # Every setting, a page per tab, with the map and the creature search
    # on Where to hunt and the creatures found in the hunt's rooms on What
    # to hunt.
    module Page
      # A picker value meaning "none of these, I will type it". The hand and
      # ammunition pickers are editable selects now, so what is typed is the
      # value, but Editor#on_equipment still names this.
      OTHER = '__other__'

      # The window's opening size: a vertical tab rail plus a settings page
      # beside it without wrapping.
      WINDOW_SIZE = Editor::DEFAULT_WINDOW

      # Settings whose entries are creature names, which the chosen area can
      # fill in.
      CREATURE_LISTS = Schema::CREATURE_LIST_KEYS

      # Settings whose entries are room numbers.
      ROOM_LISTS = %w[hunting_boundaries rallypoint_room_ids].freeze

      # The full editor's tabs: every settings page, then the two that are
      # not settings.
      PAGES = Editor::NAV_ITEMS.freeze

      # Width of a one-line control, in characters. A room number does not
      # need the whole window.
      CONTROL_WIDTH = 28

      # How wide a box for a number is: room for a few digits and a sign.
      NUMBER_WIDTH = 8

      # Each settings page's headings and the settings under them, in the
      # order they are drawn. A setting the page has and this does not name
      # is drawn under a last heading, so a field added to the schema is
      # never hidden.
      GROUPS = {
        'area'      => [
          ['Rooms', %w[hunting_room_id hunting_boundaries rallypoint_room_ids]]
        ],
        'creatures' => [
          ['What to hunt', %w[targets invalid_targets always_flee_from quickhunt_targets]],
          ['Boon creatures', %w[boons_ignore boons_flee]],
          ['Tracking', [%w[track track_creature]]]
        ],
        # An inner list is one line: the first setting's label in the label
        # column, the rest beside it.
        'hunting'   => [
          ['Stance', [%w[hunting_stance wander_stance stand_stance]]],
          ['Targets and leaving', [%w[flee_count lone_targets_only], %w[wander_wait priority], 'flee_message', 'sneaky_sneaky', 'weapon_reaction']],
          ['Room hazards', %w[flee_clouds flee_vines flee_webs flee_voids ignore_disks]],
          ['Looting', ['loot_script', %w[delay_loot loot_stance final_loot]]],
          ['Test options', %w[turbo]]
        ],
        # A third element, :fold, keeps the group behind a button.
        'rest'      => [
          ['When to return', [%w[fried overkill lte_boost], %w[oom encumbered encumbrance_grace_seconds], 'wounded_eval',
                              %w[creeping_dread crushing_dread], 'wot_poison', 'confusion']],
          ['Town rest', ['resting_room_id', 'return_waypoint_ids', 'resting_commands', 'resting_scripts',
                         %w[rest_till_exp rest_till_mana], %w[rest_till_spirit rest_till_percentstamina], 'after_town_rest']],
          ['Getting home', %w[fog_return custom_fog fog_optional fog_rift]],
          ['Field rest', %w[field_rest_room_id field_rest_for town_rest_required_eval field_rest_commands field_rest_scripts
                            field_hunting_prep_commands field_rest_timeout_seconds field_return_waypoint_ids
                            field_rallypoint_room_ids], :fold]
        ],
        'combat'    => [
          ['Routines', %w[hunting_commands hunting_commands_b hunting_commands_c hunting_commands_d
                          hunting_commands_e hunting_commands_f hunting_commands_g hunting_commands_h
                          hunting_commands_i hunting_commands_j quick_commands disable_commands]],
          ['Aiming', %w[ambush archery_aim aim], :fold],
          ['UAC & MSTRIKE', ['tier3', 'uac_smite', 'uac_mstrike',
                             %w[mstrike_mob mstrike_stamina_cooldown mstrike_stamina_quickstrike],
                             'mstrike_cooldown', 'mstrike_quickstrike'], :fold]
        ],
        'equipment' => [
          ['Hands', [%w[hunting_right_hand hunting_aim], 'hunting_left_hand']],
          ['Upkeep', %w[signs hunting_scripts wracking_spirit bless use_wracking check_favor]],
          ['Pre-hunt', %w[hunting_prep_commands]],
          ['Ammunition', %w[ammo ammo_container], :fold],
          ['Wands', %w[wand fresh_wand_container dead_wand_container wand_if_oom], :fold],
          ['Loadouts', %w[hunting_loadout_rules hunting_loadout_sets], :fold]
        ],
        'recovery'  => [
          ['In the group', %w[troubadours_rally group_aid pull deader]],
          ['Cleanse', %w[recovery]],
          ['Death', %w[dead_man_switch depart_switch]]
        ],
        'team'      => [
          ['Travel', %w[independent_travel independent_return group_strict_movement]],
          ['Looting', [%w[ma_looter final_looter], 'never_loot', 'random_loot']],
          ['Coordination', %w[group_deader quiet_followers group_fried_trigger]]
        ]
      }.freeze

      # Seconds a condition may run before Test now gives up on it.
      TEST_LIMIT = 5

      module_function

      # Draw the page.
      #
      # @param ui [#component] the tree builder
      # @param editor [Editor] the editing session
      # @param session [#call, #test_results] handles events: called with the
      #   handler name, the event and any curried arguments
      # @return [void]
      def render(ui, editor, session)
        ui.stack(key: "root-#{editor.draft_serial}", gap: 8, margin: 10) do
          Page.toolbar(ui, editor, session)
          Page.status(ui, editor, session)
          Page.full(ui, editor, session)
        end
      end

      # A handler bound to one control: the session is called with the name,
      # the event and the curried arguments.
      def on(session, name, *args)
        proc { |event| session.call(name, event, *args) }
      end

      # The bar above everything, one row: what to work on and its name, then
      # whether it is saved and the draft's buttons.
      def toolbar(ui, editor, session)
        ui.columns(key: 'hunt-bar', count: 8, weights: [0, 0, 0, 1, 0, 0, 0, 0], compact: true, row_align: :end) do
          ui.select(slot: '0', key: 'hunts', label: 'Hunt', options: Page.name_options(editor.profiles, 'Saved hunts'),
                    value: editor.profiles.include?(editor.name) ? editor.name : '', control_width_chars: 16,
                    tooltip: 'Hunts saved by eohunter. Choosing one opens it.',
                    on: { change: Page.on(session, :load) })
          ui.select(slot: '1', key: 'bigshot', label: 'Bigshot', options: Page.name_options(editor.legacy_profiles, 'Import a profile'),
                    value: '', control_width_chars: 16,
                    tooltip: 'Bigshot profiles, opened as an unsaved copy. The original is never written.',
                    on: { change: Page.on(session, :copy_legacy) })
          ui.button(slot: '2', key: 'new', label: 'New', tooltip: 'Start an empty hunt',
                    on: { activate: Page.on(session, :new) })
          ui.text_input(slot: '3', key: 'name', label: 'Name', value: editor.name.to_s, placeholder: 'name this hunt',
                        tooltip: 'Saving under a new name creates a new hunt and leaves the original alone.',
                        on: { change: Page.on(session, :rename) })
          ui.text(slot: '4', key: 'dirty', content: editor.dirty? ? 'Unsaved' : 'Saved',
                  tone: editor.dirty? ? :caution : :neutral, emphasis: :subtle)
          ui.button(slot: '5', key: 'validate', label: 'Validate', tooltip: 'Check the draft against the installed engine',
                    on: { activate: Page.on(session, :validate) })
          ui.button(slot: '6', key: 'save', label: 'Save', variant: :primary, tooltip: 'Write the hunt. Saving does not start it.',
                    on: { activate: Page.on(session, :save) })
          ui.button(slot: '7', key: 'revert', label: 'Revert', tooltip: 'Discard the unsaved edits',
                    on: { activate: Page.on(session, :revert) })
        end
      end

      # The search, as wide as the page list under it, and beside it what the
      # editor last said.
      def status(ui, editor, session)
        content = editor.status.to_s
        content = 'Open a hunt, import a Bigshot profile, or start a new one.' if content.empty?
        ui.columns(key: 'draft-bar', count: 2, weights: [0, 1], compact: true, row_align: :center, gap: 16) do
          ui.text_input(slot: '0', key: 'search', value: editor.query, search: true, change_mode: :input, placeholder: 'Find a setting',
                        control_width_chars: 18, on: { change: Page.on(session, :search) })
          ui.text(slot: '1', key: 'said', content: content, tone: editor.status_error ? :danger : :neutral,
                  emphasis: editor.status_error ? :strong : :normal)
        end
      end

      # --- The full editor --------------------------------------------------

      # Every setting, a page per tab, with a search across all of them.
      def full(ui, editor, session)
        return Page.search_results(ui, editor, session) unless editor.query.empty?

        # The draft names the tabs so the session can move the viewer to
        # another page: the selected tab is the viewer's own, and a redraw's
        # choice is not applied over it.
        tabs = ui.tabs(key: 'pages', names: PAGES.map { |item| item[:label] }, vertical: true, selected: editor.page_index,
                       on: { select: Page.on(session, :select_page) }) do
          # No scroll region around a tab's body: one with nothing to size it
          # measures as zero in the browser and the tab draws empty. The
          # window scrolls instead.
          PAGES.each_with_index do |item, index|
            ui.stack(slot: item[:label], key: item[:id], gap: 10, margin: { left: 12, right: 4 }) do
              # Only the page being looked at is drawn; the others are empty
              # until chosen. See Editor#page_index.
              next unless index == editor.page_index

              case item[:id]
              when 'manage' then Page.manage(ui, editor, session)
              when 'area'
                Page.area_map(ui, editor, session)
                Page.settings(ui, editor, editor.fields_for(item[:id]), session)
              when 'creatures'
                Page.creature_finder(ui, editor, session)
                Page.creatures_here(ui, editor, session)
                # Boons belong to boss-type creatures. With none in the
                # hunt's rooms and nothing in the boxes, the boon settings
                # are clutter and stay out of the way.
                fields = editor.fields_for(item[:id])
                fields = fields.reject { |field| %w[boons_ignore boons_flee].include?(field['key']) } unless editor.boons_relevant?
                Page.settings(ui, editor, fields, session)
                Page.boon_pickers(ui, editor, session)
              else Page.settings(ui, editor, editor.fields_for(item[:id]), session)
              end
            end
          end
        end
        editor.tabs_cid = tabs.cid
      end

      # The settings matching the search box, drawn as the pages draw them,
      # each under the name of the page it is on, in sidebar order.
      def search_results(ui, editor, session)
        found = editor.search_results
        ui.text(key: 'found', emphasis: :strong,
                content: found.empty? ? 'No setting matches' : "#{found.size} matching setting#{'s' if found.size != 1}")
        return if found.empty?

        pages = PAGES.map { |item| item[:id] }
        by_page = found.group_by { |field| field['page'] }.sort_by { |id, _| pages.index(id) || pages.size }
        ui.grid(key: 'page', cols: COLUMNS, homogeneous: false, expand_columns: [COLUMNS], gap: 6) do
          by_page.each do |id, fields|
            title = PAGES.find { |item| item[:id] == id }&.dig(:label) || id.to_s
            ui.text(key: "p-#{id}", content: title, emphasis: :strong, placement: { column: 1 })
            ui.text(key: "p-#{id}-pad", content: '', placement: WIDE)
            Page.labelled(ui, editor, fields, session)
          end
        end
      end

      # A page of settings: the usual ones under their headings, then the
      # advanced ones folded away.
      def settings(ui, editor, fields, session)
        # Every setting in its group, none folded away: what the schema
        # flags as advanced is ordinary to the people using this.
        # One grid for the whole page, so every control starts at the same
        # place whichever group it is in. Its columns are label, box, label,
        # box, label, box: a line puts each of its settings in its own pair,
        # so the second and third settings of every line line up too.
        ui.grid(key: 'page', cols: COLUMNS, homogeneous: false, expand_columns: [COLUMNS], gap: 6) do
          Page.grouped(fields).each_with_index do |(heading, members, fold), index|
            ui.text(key: "g#{index}", content: heading, emphasis: :strong, placement: { column: 1 })
            if fold
              Page.fold_button(ui, editor, heading, members, session, key: "g#{index}-pad")
              next unless editor.fold_open?(heading)
            else
              ui.text(key: "g#{index}-pad", content: '', placement: WIDE)
            end
            Page.labelled(ui, editor, members, session)
            next unless NOTES[heading]

            Page.note(ui, NOTES[heading], key: "g#{index}-note")
          end
        end
      end

      # The page grid's columns: a label and a box, three times.
      COLUMNS = 6

      # Where a control that is not on a line goes: everything after the
      # first label.
      WIDE = { column: 2, span: COLUMNS - 1 }.freeze

      # Settings kept in a saved hunt but not drawn. box_in_hand is Bigshot's,
      # and the hunt never reads it. combat_buffs and preparations work, but
      # are left for a later, friendlier editor than a box of YAML.
      HIDDEN = %w[box_in_hand combat_buffs preparations].freeze

      # A worked example under a group, shown when it is open: what the
      # settings mean, then sample text for each box, line by line.
      NOTES = {
        'Loadouts' => [
          'Swap weapons by creature. Rules pick a set by target (a creature name) or type (living, undead or noncorporeal); ' \
          'the first rule that matches wins. Sets name what to hold: right, left and aim, with anything left out taken from Hands. ' \
          'Indent the lines under a rule or a set by exactly two spaces.',
          ['Rules, for example:', *Schema::LOADOUT_RULES_EXAMPLE],
          ['Sets, for example:', *Schema::LOADOUT_SETS_EXAMPLE]
        ]
      }.freeze

      # Short labels for settings drawn on one line, where the heading
      # already says what they are.
      LINE_LABELS = {
        'hunting_stance' => 'Attack', 'wander_stance' => 'Wander', 'stand_stance' => 'Stand-up',
        'hunting_right_hand' => 'Right', 'hunting_left_hand' => 'Left', 'hunting_aim' => 'Aim',
        'signs' => 'Spells', 'wracking_spirit' => 'Keep spirit', 'hunting_prep_commands' => 'Commands', 'hunting_scripts' => 'Hunting scripts',
        'combat_buffs' => 'Buffs', 'preparations' => 'Commands', 'hunting_loadout_sets' => 'Sets', 'hunting_loadout_rules' => 'Rules',
        'group_fried_trigger' => 'Fried trigger', 'tier3' => 'Excellent', 'mstrike_mob' => 'MSTRIKE at', 'mstrike_stamina_cooldown' => 'Cooldown at', 'mstrike_stamina_quickstrike' => 'QUICKSTRIKE at',
        'overkill' => 'Overkill', 'lte_boost' => 'LTE', 'encumbrance_grace_seconds' => 'for', 'rest_till_mana' => 'Mana',
        'rest_till_percentstamina' => 'Stamina'
      }.freeze

      # The page's fields under their headings, in GROUPS order, with what
      # GROUPS does not name under a last heading so nothing is lost. A
      # member is a field, or an Array of fields drawn on one line. A setting
      # the installed engine does not have is left out.
      # @return [Array<Array(String, Array<Hash, Array<Hash>>)>]
      def grouped(fields)
        page = fields.first && fields.first['page']
        by_key = fields.to_h { |field| [field['key'], field] }
        placed = {}
        HIDDEN.each { |key| placed[key] = true }
        groups = Array(GROUPS[page]).filter_map do |(heading, keys, fold)|
          members = keys.filter_map do |entry|
            if entry.is_a?(Array)
              line = entry.filter_map { |key| by_key[key] }
              line.size > 1 ? line : line.first
            else
              by_key[entry]
            end
          end
          members.flatten.each { |field| placed[field['key']] = true }
          [heading, members, fold == :fold] unless members.empty?
        end
        rest = fields.reject { |field| placed[field['key']] }
        groups << [groups.empty? ? 'Settings' : 'Other', rest] unless rest.empty?
        groups
      end

      # A group's rows in the page grid, in order: each label beside its
      # control, a line of settings where GROUPS asks for one, and ticks two
      # to a row. A setting drawn its own way (Cleanse) sits in the control
      # column whole.
      def labelled(ui, editor, members, session)
        ticks = []
        flush = lambda do
          # Ticks three to a row in a grid of their own from the box column:
          # their columns line up row to row, and stay out of the line
          # columns, which boxes size.
          unless ticks.empty?
            ui.text(key: "l-#{ticks.first['key']}", content: '', placement: { column: 1 })
            ui.grid(key: "t-#{ticks.first['key']}", cols: [ticks.size, 3].min, homogeneous: false, column_gap: 28, row_gap: 4,
                    placement: WIDE) do
              ticks.each { |field| Page.field_row(ui, editor, field, session) }
            end
          end
          ticks.clear
        end
        members.each do |member|
          if member.is_a?(Array) && member.all? { |field| Form.kind(editor, field) == :check }
            flush.call
            ticks.concat(member)
            flush.call
          elsif member.is_a?(Array)
            flush.call
            Page.line(ui, editor, member, session)
          elsif FLOWING.include?(member['key'])
            flush.call
            Page.flowing_line(ui, editor, [member], session)
          elsif member['key'] == 'recovery'
            flush.call
            Page.cleanse_rows(ui, editor, session)
          elsif Form.kind(editor, member) == :check
            ticks << member
          else
            flush.call
            key = member['key']
            ui.text(key: "l-#{key}", content: Page.short_label(member), tooltip: Form.tooltip(editor, member), placement: { column: 1 })
            ui.stack(key: "f-#{key}", gap: 2, placement: WIDE) do
              Page.control(ui, editor, member, session, bare: true)
              Page.messages(ui, editor, key)
            end
          end
        end
        flush.call
      end

      # Several settings on one line of the page grid, each in its own
      # label and box columns, so a line's second and third settings sit
      # under the line above's. A tick takes its label column and box column
      # both. What validation said goes on a row of its own beneath.
      def line(ui, editor, fields, session)
        return Page.flowing_line(ui, editor, fields, session) if FLOWING.include?(fields.first['key'])

        name = ->(field) { Page.short_label(field) }
        fields.each_with_index do |field, index|
          key = field['key']
          label_column = 1 + (2 * index)
          if Form.kind(editor, field) == :check
            ui.text(key: "l-#{key}", content: '', placement: { column: 1 }) if index.zero?
            Page.control(ui, editor, field, session, label: name.call(field),
                                                     placement: { column: label_column + 1, span: [2, COLUMNS - label_column].min })
          else
            ui.text(key: "l-#{key}", content: name.call(field), tooltip: Form.tooltip(editor, field), placement: { column: label_column })
            Page.control(ui, editor, field, session, bare: true, width: LINE_WIDTHS.fetch(key, LINE_WIDTH),
                                                     placement: { column: label_column + 1 })
          end
        end
        found = fields.flat_map { |field| Form.messages(editor, field['key']) }
        return if found.empty?

        ui.text(key: "line-#{fields.first['key']}-pad", content: '', placement: { column: 1 })
        ui.stack(key: "line-#{fields.first['key']}", gap: 2, placement: WIDE) do
          fields.each { |field| Page.messages(ui, editor, field['key']) }
        end
      end

      # Lines laid out at their own natural spacing after the first label,
      # rather than in the page's columns: their boxes are wider than the
      # number boxes that size those columns.
      FLOWING = %w[hunting_right_hand hunting_left_hand ma_looter].freeze

      # A line after its first label, one control and label after another.
      def flowing_line(ui, editor, fields, session)
        first = fields.first
        ui.text(key: "l-#{first['key']}", content: Page.short_label(first), tooltip: Form.tooltip(editor, first), placement: { column: 1 })
        ui.stack(key: "line-#{first['key']}", gap: 2, placement: WIDE) do
          cells = (fields.size * 2) - 1
          ui.columns(key: 'cells', count: cells, weights: Array.new(cells, 0), gap: 10, row_align: :center) do
            fields.each_with_index do |field, index|
              key = field['key']
              ui.text(slot: ((2 * index) - 1).to_s, key: "l-#{key}", content: Page.short_label(field), tooltip: Form.tooltip(editor, field)) if index.positive?
              Page.control(ui, editor, field, session, bare: true, width: LINE_WIDTHS.fetch(key, LINE_WIDTH), slot: (2 * index).to_s)
            end
          end
          fields.each { |field| Page.messages(ui, editor, field['key']) }
        end
      end

      # How wide a box on a shared line is, in characters.
      LINE_WIDTH = 10

      # Boxes on a shared line that need more room than that: item names.
      LINE_WIDTHS = { 'hunting_right_hand' => 16, 'hunting_left_hand' => 16, 'hunting_aim' => 12, 'ma_looter' => 14,
                      'final_looter' => 14 }.freeze

      # The button beside a folded group's heading: Show, with how many of
      # its settings this hunt sets, so a closed group in use is not missed.
      def fold_button(ui, editor, heading, members, session, key:)
        open = editor.fold_open?(heading)
        set = members.flatten.count { |field| Page.in_use?(editor, field) }
        label = open ? 'Hide' : "Show#{" (#{set} set)" if set.positive?}"
        ui.columns(key: key, count: 1, weights: [0], compact: true, placement: WIDE) do
          ui.button(slot: '0', key: 'fold', label: label, on: { activate: Page.on(session, :toggle_fold, heading) })
        end
      end

      # What a setting is called in the page grid: a short word where the
      # heading already says the rest, else its label.
      def short_label(field)
        key = field['key']
        LINE_LABELS[key] || ROUTINE_WORDS[key] || AIM_LABELS[key] || Form.label(field)
      end

      # Whether this hunt has the setting at something other than its
      # default: a tick saved as off, or an emptied box, is not in use.
      def in_use?(editor, field)
        return false unless editor.settings.key?(field['key'])

        value = editor.settings[field['key']]
        !(value.nil? || value == false || value == '' || value == [] || value == {} || value == field['default'])
      end

      # A non-breaking space, built from its code point: the source stays ASCII.
      NBSP = [160].pack('U').freeze

      # A group's worked example: its sentence wrapped to the page, then each
      # sample as lines of text. Leading spaces are made non-breaking so the
      # indentation that YAML needs survives the browser.
      def note(ui, (sentence, *samples), key:)
        ui.text(key: "#{key}-pad", content: '', placement: { column: 1 })
        ui.stack(key: key, gap: 6, placement: WIDE) do
          ui.text(key: 'sentence', content: sentence, emphasis: :subtle, wrap: true, max_width_chars: 64)
          ui.columns(key: 'samples', count: samples.size, weights: Array.new(samples.size, 0), gap: 40, row_align: :start) do
            samples.each_with_index do |lines, index|
              ui.stack(slot: index.to_s, key: "sample#{index}", gap: 0) do
                lines.each_with_index do |line, number|
                  ui.text(key: "l#{number}", content: line.sub(/\A +/) { |spaces| NBSP * (spaces.size * 2) },
                          emphasis: number.zero? ? :strong : :normal)
                end
              end
            end
          end
        end
      end

      # How many characters a validation message runs before it wraps, so a
      # long one does not stretch the page grid wider than the window.
      MESSAGE_WIDTH = 50

      # What validation said about a setting, under its control.
      def messages(ui, editor, key)
        Form.messages(editor, key).each_with_index do |message, index|
          ui.text(key: "m-#{key}-#{index}", content: message, tone: :danger, emphasis: :subtle, max_width_chars: MESSAGE_WIDTH)
        end
      end

      # One setting: its control, then what validation said about it. What
      # the setting does is in the control's tooltip, not on the page.
      def field_row(ui, editor, field, session, slot: nil, placement: {})
        key = field['key']
        ui.stack(key: "f-#{key}", slot: slot, gap: 2, placement: placement) do
          Page.control(ui, editor, field, session)
          Form.messages(editor, key).each_with_index do |message, index|
            ui.text(key: "m#{index}", content: message, tone: :danger, emphasis: :subtle, max_width_chars: MESSAGE_WIDTH)
          end
        end
      end

      # The control a setting gets, from Form.kind.
      # @param bare [Boolean] leave the label off, for a control whose label
      #   is drawn beside it
      # @param slot [String, nil] the slot it fills in a line
      # @param label [String, nil] a label to use in place of the field's
      # @param width [Integer, nil] a width to use in place of the usual one
      # @param placement [Hash] where it sits in the page grid
      def control(ui, editor, field, session, bare: false, slot: nil, label: nil, width: nil, placement: {})
        key = field['key']
        value = editor.settings[key]
        label = bare ? nil : (label || Form.label(field))
        named = label ? { label: label } : {}
        named[:slot] = slot if slot
        named[:placement] = placement unless placement.empty?
        size = width || CONTROL_WIDTH
        tip = Form.tooltip(editor, field)
        case Form.kind(editor, field)
        when :check
          ui.checkbox(key: key, **named, checked: value == true, tooltip: tip,
                      on: { change: Page.on(session, :change, key) })
        when :choice
          options = Form.choices(field, value)
          value = Schema::ALIASES.dig(key, value.to_s) || value
          ui.select(key: key, **named, tooltip: tip, control_width_chars: size,
                    options: options.map { |(id, text)| { value: id, label: text } },
                    value: Form.chosen(options, value) || '',
                    on: { change: Page.on(session, :change, key) })
        when :equipment
          ui.select(key: key, **named, tooltip: tip, editable: true, control_width_chars: size,
                    options: Page.equipment_options(editor.equipment_options(key)),
                    value: value.to_s, placeholder: 'as it appears in your inventory',
                    on: { change: Page.on(session, :change, key) })
        when :ruby
          Page.ruby(ui, editor, field, session, bare: bare)
        when :list
          Page.list(ui, editor, field, session, bare: bare)
        when :text_block
          text = Form.text(value)
          ui.textarea(key: key, **(label ? { label: field['type'] == 'structured' ? "#{label} (YAML)" : label } : {}), tooltip: tip,
                      value: text, rows: Page.rows_for(text), wrap: :none,
                      on: { blur: Page.on(session, :change, key) })
        else
          text = Form.text(value)
          # A number is a few digits and gets a box that size; a creature
          # list runs the width of the page like its neighbours.
          width = if %w[integer number].include?(field['type']) then NUMBER_WIDTH
                  elsif width then width
                  elsif CREATURE_LISTS.include?(key) then nil
                  else CONTROL_WIDTH
                  end
          placeholder = if CREATURE_LISTS.include?(key) then 'comma separated'
                        elsif width == NUMBER_WIDTH && !Form.units(field).empty? then Form.units(field)
                        else Page.default_hint(field)
                        end
          ui.text_input(key: Page.box_key(key, text), **named, tooltip: tip, value: text,
                        placeholder: placeholder,
                        **(width ? { control_width_chars: width } : {}),
                        on: { change: Page.on(session, :change, key) })
        end
      end

      # The key of a box the map writes to. The browser keeps what a viewer
      # typed in a box across redraws, by the box's identity, and can put
      # that back over what the map just set. A box the map writes carries
      # its value in its identity, so a value the map changes is a new box
      # with nothing to put back; a box the map does not touch keeps its
      # identity, and the typing in it.
      def box_key(key, text)
        return key unless Geography::MAP_SETTINGS.include?(key) || CREATURE_LISTS.include?(key)

        "#{key}-#{Digest::SHA256.hexdigest(text.to_s)[0, 8]}"
      end

      # Cleanse in the page grid: each list under its name with its ticks
      # three across, a sub-heading starting a new row and the safe room
      # under the itchy curse it is for, then the one-time import, last: it
      # is used once, and the ticks are what a hunt is set up with.
      def cleanse_rows(ui, editor, session)
        # One grid for every list, across the whole page, so the lists' columns
        # line up with each other and the longest names fit.
        ui.grid(key: 'cleanse', cols: 3, homogeneous: false, column_gap: 24, row_gap: 4, placement: { column: 1, span: COLUMNS }) do
          Schema::RECOVERY_CONTROLS.each do |(heading, controls)|
            ui.text(key: "h-#{heading.tr(' ', '-')}", content: heading, emphasis: :strong, placement: { column: 1, span: 3 })
            controls.each do |entry|
              case entry
              when :safe_room
                tip = 'Room to run to with the itchy curse. Empty runs to the nearest town or sanctuary.'
                ui.columns(key: 'safe-room', count: 2, weights: [0, 0], compact: true, row_align: :center, gap: 12,
                           placement: { column: 1, span: 3 }) do
                  ui.text(slot: '0', key: 'label', content: 'Safe room', tooltip: tip)
                  ui.text_input(slot: '1', key: 'safe_room', value: editor.recovery_value('safe_room').to_s,
                                placeholder: 'nearest town or sanctuary', control_width_chars: CONTROL_WIDTH, tooltip: tip,
                                on: { change: Page.on(session, :recovery_set, 'safe_room') })
                end
              when String
                ui.text(key: "s-#{entry.downcase.gsub(/[^a-z]+/, '-')}", content: entry, emphasis: :subtle, placement: { column: 1, span: 3 })
              else
                key, label, tip = entry
                checked = editor.recovery_value(key) == true
                # What this character cannot use is greyed out, as in ecleanse's
                # window; one already ticked stays clickable, to untick.
                why = editor.recovery_unusable(key)
                tip = [why && (checked ? "#{why} Ticked, but it does nothing; untick it." : why), tip].compact.join(' ')
                ui.checkbox(key: key, label: label, checked: checked, disabled: !why.nil? && !checked,
                            **(tip.empty? ? {} : { tooltip: tip }), on: { change: Page.on(session, :recovery_set, key) })
              end
            end
          end
        end
        return unless editor.ecleanse_to_import?

        ui.text(key: 'l-import', content: '', placement: { column: 1 })
        ui.columns(key: 'import', count: 1, weights: [0], compact: true, placement: WIDE) do
          ui.button(slot: '0', key: 'import-ecleanse', label: 'Import from ecleanse',
                    tooltip: 'Copy what standalone ecleanse has set into this hunt, replacing the ticks above. Save to keep them. ecleanse is not changed.',
                    on: { activate: Page.on(session, :import_ecleanse) })
        end
      end

      # A Ruby condition, with a button that runs it where the hunt would.
      def ruby(ui, editor, field, session, bare: false)
        key = field['key']
        ui.columns(key: key, count: 2, weights: [1, 0], row_align: :end) do
          ui.text_input(slot: '0', key: 'code', **(bare ? {} : { label: Form.label(field) }), tooltip: Form.tooltip(editor, field),
                        value: Form.text(editor.settings[key]), placeholder: Page.default_hint(field),
                        on: { change: Page.on(session, :change, key) })
          ui.button(slot: '1', key: 'test', label: 'Test now',
                    tooltip: 'Run this condition now, as the hunt would, and show what it says. ' \
                             'It reads your character as they are at this moment.',
                    on: { activate: Page.on(session, :test_condition, key) })
        end
        result = session.test_results[key]
        ui.text(key: "#{key}-result", content: result.to_s, emphasis: :subtle) if result
      end

      # What an empty box says: the engine's default when it has one worth
      # showing, otherwise nothing.
      # @return [String]
      def default_hint(field)
        default = field['default']
        return '' if default.nil? || default == false || default == '' || default == [] || default == {}

        "default #{Form.text(default)}"
      end

      # A comma list, one entry per line.
      def list(ui, editor, field, session, bare: false)
        key = field['key']
        text = editor.list_entries(key).join(', ')
        ui.text_input(key: Page.box_key(key, text), **(bare ? {} : { label: Form.label(field) }), tooltip: Form.tooltip(editor, field),
                      value: text, placeholder: 'comma separated',
                      on: { change: Page.on(session, :list_set_all, key) })
      end

      # The routine settings and the word beside each box: a letter for the
      # creature routines, then the two special sequences.
      ROUTINE_WORDS = GROUPS['combat'][0][1].to_h do |key|
        word = case key
               when 'hunting_commands' then 'a'
               when 'quick_commands' then 'Quick'
               when 'disable_commands' then 'Fried'
               else key[-1]
               end
        [key, word]
      end.freeze

      # The aiming settings and the word each is known by.
      AIM_LABELS = { 'ambush' => 'Ambush', 'archery_aim' => 'Ranged', 'aim' => 'Unarmed' }.freeze

      # A section's heading: bold, as the settings pages' are, with Show or
      # Hide beside it when the section folds. No frame: a group's border
      # sits tight on its contents in compact density, and the settings
      # pages fold without one.
      # @param open [Boolean, nil] whether it is open; nil when it does not fold
      # @param toggle [Symbol, nil] the session handler that folds it
      def section_heading(ui, key, title, session, open: nil, toggle: nil)
        ui.columns(key: "#{key}-heading", count: 2, weights: [0, 0], compact: true, row_align: :center, gap: 12) do
          ui.text(slot: '0', key: 'title', content: title, emphasis: :strong)
          ui.button(slot: '1', key: 'fold', label: open ? 'Hide' : 'Show', on: { activate: Page.on(session, toggle) }) if toggle
        end
      end

      # What else lives where the hunt is, each with a tick for hunting it:
      # the rooms the hunt walks once it has a start, the fenced rooms before
      # then. A fence of several areas lists each area apart, as a hunt walks
      # only the one its start room is in. Then the step to the map.
      def creatures_here(ui, editor, session)
        creatures = editor.creatures_here
        walked = !editor.hunt_rooms.empty?
        if creatures.empty?
          ui.text(key: 'here-none', emphasis: :subtle,
                  content: 'Pick a creature above, or set the rooms on Where to hunt, and what lives there is listed here.')
          return
        end

        areas = editor.creatures_by_area
        Page.section_heading(ui, 'here', walked ? 'Creatures in the hunt\'s rooms' : 'Creatures in the fence', session)
        ui.stack(key: 'here', gap: 4) do
          hint = 'Ticked goes in Creatures to hunt; unticked goes in Creatures to ignore. Neither until you tick or untick it.'
          unless walked
            hint += if areas.empty?
                      ' Choosing the start room narrows this to the rooms the hunt walks.'
                    else
                      " #{editor.fence_creature} lives in #{areas.size} separate areas, and a hunt walks one: " \
                        'the one its start room is in. Hunt the creatures of that area.'
                    end
          end
          ui.text(key: 'hint', emphasis: :subtle, content: hint)
          if areas.empty?
            Page.creature_ticks(ui, editor, creatures, session, key: 'all')
          else
            areas.each_with_index do |area, index|
              ui.text(key: "area-#{index}-heading", content: "Area #{index + 1}, #{area[:rooms].size} room#{'s' if area[:rooms].size != 1}", emphasis: :strong)
              Page.creature_ticks(ui, editor, area[:creatures], session, key: "area-#{index}")
            end
          end
          unless walked
            ui.columns(key: 'here-next', count: 1, weights: [0], compact: true) do
              ui.button(slot: '0', key: 'next', label: 'Next: choose the start room', variant: :primary,
                        tooltip: 'Where to hunt, with the map on the fence and a left-click setting the start room.',
                        on: { activate: Page.on(session, :show_page, 'area') })
            end
          end
        end
      end

      # A list of creatures, a tick each, and Hunt all of these for the list.
      # @param key [String] this list's own key, unique on the page
      def creature_ticks(ui, editor, creatures, session, key:)
        ui.stack(key: key, gap: 4) do
          ui.collection(creatures) do |creature, _|
            name = creature[:name].to_s
            level = creature[:level] ? "level #{creature[:level]}" : 'level unknown'
            traits = creature[:undead] ? ', undead' : ''
            boss = creature[:boss_type].to_s
            boss = 'boss' if boss.empty? && creature[:boss] == true
            traits += ", #{boss}" unless boss.empty?
            ui.columns(key: Page.row_key('c', name), count: 2, weights: [0, 1], compact: true, row_align: :center) do
              # Keyed by where the creature is now: the browser keeps a tick
              # it was given, so Hunt all, or a box typed in, has to make a new
              # box for the tick to follow the hunt.
              state = if editor.listed?('targets', name) then 'on'
                      elsif editor.listed?('invalid_targets', name) then 'off'
                      else 'unset'
                      end
              ui.checkbox(slot: '0', key: "hunt-#{state}", label: name, checked: state == 'on',
                          tooltip: editor.listed?('invalid_targets', name) ? 'In Creatures to ignore.' : "Tick to hunt #{name}.",
                          on: { change: Page.on(session, :hunt_creature, name) })
              ui.text(slot: '1', key: 'about', content: "#{level}#{traits}", emphasis: :subtle)
            end
          end
          ui.columns(key: 'buttons', count: 1, weights: [0], compact: true) do
            ui.button(slot: '0', key: 'hunt-all', label: 'Hunt all of these',
                      tooltip: 'Tick every creature in this list: all into Creatures to hunt, none left in Creatures to ignore.',
                      on: { activate: Page.on(session, :hunt_all, creatures.map { |creature| creature[:name].to_s }) })
          end
        end
      end

      # The boons the target reader knows, under each boon box, each with
      # the ASSESS words that reveal it, what it does, and a tick that puts
      # it in that box. Behind a button per box.
      def boon_pickers(ui, editor, session)
        boons = editor.boon_abilities
        return if boons.empty?

        unless editor.boons_relevant?
          ui.text(key: 'no-boons', emphasis: :subtle,
                  content: 'No boss-type creatures in these rooms. The boon settings appear when there are.')
          return
        end

        ui.columns(key: 'boon-buttons', count: 2, weights: [0, 0], compact: true) do
          { 'boons_ignore' => 'avoid', 'boons_flee' => 'flee from' }.each_with_index do |(key, verb), index|
            ui.button(slot: index.to_s, key: "show-#{key}", label: "#{editor.boons_open?(key) ? 'Hide' : 'Pick'} boons to #{verb}",
                      tooltip: 'Every boon the hunter can read from ASSESS, with what it does.',
                      on: { activate: Page.on(session, :toggle_boons, key) })
          end
        end
        %w[boons_ignore boons_flee].each do |key|
          next unless editor.boons_open?(key)

          Page.section_heading(ui, "pick-#{key}", key == 'boons_ignore' ? 'Boons to avoid targeting' : 'Boons to flee from', session)
          ui.stack(key: "pick-#{key}", gap: 4) do
            ui.text(key: 'source', emphasis: :subtle,
                    content: 'What each does is from the wiki\'s boss creature page, which says its notes may be inaccurate.')
            ui.collection(boons) do |boon, _|
              ui.columns(key: boon[:key].to_s, count: 2, weights: [0, 1], compact: true, row_align: :center) do
                ui.checkbox(slot: '0', key: 'tick', label: boon[:label].to_s, checked: editor.listed?(key, boon[:key].to_s),
                            tooltip: "ASSESS says: #{Array(boon[:adjectives]).join(', ')}.",
                            on: { change: Page.on(session, :toggle_boon, key, boon[:key].to_s) })
                ui.text(slot: '1', key: 'what', emphasis: :subtle,
                        content: "#{Array(boon[:adjectives]).join(', ')}. #{boon[:effect]}".strip)
              end
            end
          end
        end
      end

      # The Hunts page: every saved hunt, one a line, then what is unsaved in
      # the open one and what the last check said. Opening a hunt and
      # importing a Bigshot profile are the toolbar's.
      def manage(ui, editor, session)
        ui.stack(key: 'hunts', gap: 6) do
          ui.text(key: 'saved-heading', content: 'Saved hunts', emphasis: :strong)
          if editor.profiles.empty?
            ui.text(key: 'none', content: 'No hunts saved yet. Name the draft and save it.', emphasis: :subtle)
          else
            ui.collection(editor.profiles) { |name, _| Page.hunt_line(ui, editor, name, session) }
          end
        end
        Page.review(ui, editor)
      end

      # One saved hunt: its name, Default making it the hunt a bare
      # ;eohunter starts, and Delete, which asks in a dialog first.
      def hunt_line(ui, editor, name, session)
        key = Page.row_key('h', name)
        ui.columns(key: key, count: 3, weights: [1, 0, 0], compact: true, row_align: :center) do
          ui.text(slot: '0', key: 'name', content: name, emphasis: name == editor.name ? :strong : :normal,
                  tooltip: name == editor.name ? 'Open now.' : 'Open it from Hunt on the toolbar.')
          # Keyed by whether it is the default: the browser keeps a tick it
          # was given, so when another hunt becomes the default this one is a
          # new box, unticked, and not the old tick left showing.
          default = name == editor.active_profile
          ui.checkbox(slot: '1', key: "default-#{default ? 'on' : 'off'}", label: 'Default', checked: default,
                      tooltip: 'The hunt ;eohunter on its own starts. Ticking it never starts it.',
                      on: { change: Page.on(session, :set_default, name) })
          ui.button(slot: '2', key: 'delete', label: 'Delete', tooltip: 'Asks first. A backup is kept.',
                    on: { activate: Page.on(session, :request_delete, name) })
        end
      end

      # What is unsaved in the open hunt, and what the last check said.
      # Validate and Save are on the toolbar.
      def review(ui, editor)
        changes = editor.changes
        ui.stack(key: 'changes', gap: 6) do
          ui.text(key: 'heading', content: changes.empty? ? 'No unsaved changes' : "Unsaved changes (#{changes.size})", emphasis: :strong)
          unless changes.empty?
            ui.table(key: 'list', max_height: 300,
                     columns: [{ key: 'key', label: 'Setting' }, { key: 'before', label: 'Was' }, { key: 'after', label: 'Now' }],
                     rows: changes.map do |change|
                       { key: Page.row_key('c', change['key']),
                         cells: { 'key'    => change['key'].to_s,
                                  'before' => Form.change_text(change['before'], 'unset'),
                                  'after'  => Form.change_text(change['after'], 'removed') } }
                     end)
          end
        end
        ui.stack(key: 'validation', gap: 4) do
          ui.text(key: 'heading', content: 'Last check', emphasis: :strong)
          if editor.validation.nil?
            ui.text(key: 'none', content: 'Not checked yet. Validate checks the draft against the installed engine.', emphasis: :subtle)
          else
            { 'Errors' => [editor.errors, :danger], 'Warnings' => [editor.warnings, :caution] }.each do |title, (entries, tone)|
              next if entries.empty?

              ui.text(key: title.downcase, content: "#{title} (#{entries.size})", emphasis: :strong, tone: tone)
              entries.each_with_index do |entry, index|
                ui.text(key: "#{title.downcase}-#{index}", content: Form.message(entry), tone: tone)
              end
            end
            ui.text(key: 'clean', content: 'No problems found.', tone: :positive) if editor.errors.empty? && editor.warnings.empty?
          end
        end
      end

      # The level band the creatures are searched in.
      # The three-state filters: a flag the templates record for every
      # creature, or a trait recorded for only some.
      YES_NO = [{ value: '', label: 'any' }, { value: 'yes', label: 'yes' }, { value: 'no', label: 'no' }].freeze

      # The sparse traits offered as filters, with what each is called.
      TRAIT_LABELS = { sleepable: 'Sleepable', witherable: 'Witherable', sympathy: 'Sympathy', muggable: 'Muggable',
                       blood: 'Has blood', bones: 'Has bones', limbs: 'Has limbs' }.freeze

      # The level band and the other things a creature is chosen on.
      # @param label [String, nil] the heading, or nil for none when the
      #   caller has already said what this is
      def level_range(ui, editor, session, label: 'Find creatures')
        query = editor.hunt_query
        catalogue = editor.creature_catalogue
        Page.section_heading(ui, 'range', label, session) if label
        ui.stack(key: 'range', gap: 4) do
          # Two rows: the band and the name, then the four kinds. One row
          # of seven ran off the page.
          ui.columns(key: 'levels', count: 3, weights: [0, 0, 1], compact: true, row_align: :end) do
            ui.number_input(slot: '0', key: 'low', label: 'Level from', value: query[:low] || 1, min: 1, max: 999, stepper_buttons: true,
                            tooltip: "Lowest creature level to list. Opens at #{Creatures::LEVEL_BELOW} below your own level.",
                            on: { change: Page.on(session, :hunt_filter, :low) })
            ui.number_input(slot: '1', key: 'high', label: 'to', value: query[:high] || 999, min: 1, max: 999, stepper_buttons: true,
                            tooltip: "Highest creature level to list. Opens at #{Creatures::LEVEL_ABOVE} above your own level.",
                            on: { change: Page.on(session, :hunt_filter, :high) })
            ui.text_input(slot: '2', key: 'name', label: 'Name', value: query[:name].to_s, search: true, change_mode: :input, placeholder: 'any creature',
                          control_width_chars: 20, tooltip: 'Part of a creature name. This also finds creatures with no recorded level.',
                          on: { change: Page.on(session, :hunt_filter, :name) })
          end
          ui.columns(key: 'kinds', count: 5, weights: [0, 0, 0, 0, 0], compact: true, row_align: :end) do
            ui.select(slot: '0', key: 'undead', label: 'Undead', options: YES_NO, value: Page.yes_no(query[:undead]),
                      tooltip: 'Undead creatures only, living only, or either.',
                      on: { change: Page.on(session, :hunt_filter, :undead) })
            ui.select(slot: '1', key: 'types', label: 'Type', options: Page.name_options(Creatures.values_for(catalogue, :type), 'any'),
                      value: Array(query[:types]).first.to_s, tooltip: 'Body type, as the creature templates record it.',
                      on: { change: Page.on(session, :hunt_filter, :types) })
            ui.select(slot: '2', key: 'classes', label: 'Class', options: Page.name_options(Creatures.classes_for(catalogue), 'any'),
                      value: Array(query[:classes]).first.to_s,
                      tooltip: 'A further classification such as non-corporeal undead. Few creatures carry one.',
                      on: { change: Page.on(session, :hunt_filter, :classes) })
            ui.select(slot: '3', key: 'families', label: 'Family', options: Page.name_options(Creatures.values_for(catalogue, :family), 'any'),
                      value: Array(query[:families]).first.to_s, tooltip: 'The creature family: rolton, troll, wraith.',
                      on: { change: Page.on(session, :hunt_filter, :families) })
            # The list's order, here with the filters: a sortable heading is a
            # full-size button in Lich outside compact density.
            ui.select(slot: '4', key: 'sort', label: 'Sort by', value: editor.creature_sort, control_width_chars: 9,
                      options: Editor::CREATURE_SORTS.map { |value, label| { value: value, label: label } },
                      on: { change: Page.on(session, :creature_sort) })
          end
          ui.expander(key: 'more', label: 'More filters', on: { toggle: proc {} }) do
            # Boss and the seven traits, four to a row.
            filters = [[:boss, 'Boss', 'Boss creatures only, ordinary ones only, or either.']] +
                      TRAIT_LABELS.map { |trait, label| [trait, label, nil] }
            filters.each_slice(4).with_index do |row, row_index|
              ui.columns(key: "traits-#{row_index}", count: 4, weights: [0, 0, 0, 0], compact: true, row_align: :end) do
                row.each_with_index do |(field, label, tip), index|
                  if tip.nil?
                    tally = editor.trait_tally(field)
                    tip = "Of the creatures listed: #{tally[:yes]} yes, #{tally[:no]} no, #{tally[:unknown]} not recorded. " \
                          'A creature with nothing recorded is kept either way.'
                  end
                  value = field == :boss ? query[:boss] : query[:traits][field]
                  ui.select(slot: index.to_s, key: field.to_s, label: label, options: YES_NO, value: Page.yes_no(value),
                            tooltip: tip, on: { change: Page.on(session, :hunt_filter, field) })
                end
              end
            end
          end
        end
      end

      # A three-state filter as the select shows it.
      def yes_no(value)
        case value
        when true then 'yes'
        when false then 'no'
        else ''
        end
      end

      # Every creature in the range, to pick one from.
      def creature_picker(ui, editor, session)
        matches = editor.sorted_creature_matches
        ui.text(key: 'creatures-heading', content: 'Creatures in range: pick the one to hunt', emphasis: :strong)
        ui.stack(key: 'creatures', gap: 4) do
          ui.text(key: 'creature-error', content: editor.creature_error.to_s, tone: :danger) if editor.creature_error
          if matches.empty?
            ui.text(key: 'none', emphasis: :subtle,
                    content: editor.creature_catalogue.empty? ? 'No creature data is installed.' : 'No creature in this range.')
          else
            ui.table(key: 'list', selection: :single, activation: :single, max_height: 260,
                     tooltip: 'Click a creature to hunt it: it becomes the target and where it lives is fenced. Details shows what is known about it.',
                     selected: [],
                     columns: [{ key: 'name', label: 'Creature' },
                               { key: 'level', label: 'Level', align: :end },
                               { key: 'family', label: 'Family' },
                               { key: 'areas', label: 'Lives in' },
                               { key: 'details', label: '', tooltip: 'Show this creature\'s details' }],
                     rows: matches.map do |creature|
                       { key: Page.row_key('m', creature[:name]),
                         cells: { 'name' => creature[:name].to_s, 'level' => creature[:level].to_s,
                                  'family' => creature[:family].to_s, 'areas' => creature[:areas].join(', '),
                                  'details' => 'Details' } }
                     end,
                     # selection_change is bound so Lich keeps the viewer's
                     # selection: an unbound event is refused, and the next
                     # redraw then cleared the creature just picked.
                     on: { row_activate: Page.on(session, :find_creature), selection_change: proc {} })
          end
          hidden = editor.unlevelled_count
          if hidden.positive? && editor.hunt_query[:name].to_s.strip.empty?
            ui.text(key: 'unlevelled', emphasis: :subtle,
                    content: "#{hidden} creature#{'s' if hidden != 1} with no recorded level #{hidden == 1 ? 'is' : 'are'} not listed; type a name to find one.")
          end
        end
      end

      # --- The map ------------------------------------------------------------
      #
      # The creature search on Where to hunt, behind a button like the map:
      # the level band and filters, then the creatures in range. Picking one
      # fences where it lives and makes it the target.
      def creature_finder(ui, editor, session)
        open = editor.creature_search_open?
        Page.section_heading(ui, 'finder', 'Find a creature', session, open: open, toggle: :toggle_creature_search)
        return unless open

        ui.stack(key: 'finder-section', gap: 8) do
          Page.level_range(ui, editor, session, label: nil)
          Page.creature_picker(ui, editor, session)
        end
      end

      # The installed map sheet, drawn on a composite surface with one region
      # per room. A left-click puts the room in the chosen role, a right-click
      # takes it out of whatever role it holds. The hunt's rooms are washed
      # green, the start room ringed in blue, the boundaries crossed in red,
      # the rest rooms ringed in their own colours.

      # How much sheet to keep around the hunt, so the mapmaker's labels
      # beside the rooms stay in the picture.
      MAP_PADDING = 40
      MAP_CONTEXT_SHARE = 0.25
      MAP_CONTEXT_MAX = 320

      # The most layers a composite takes: Lich's BOUNDS[:collection].
      MAP_LAYERS = 512

      # How much of a room's box a mark spans.
      MARK_INSET = 0.15

      # What each role is drawn as: a symbol for the rooms worth finding, an
      # outline for the many rooms of the hunt itself. Never a fill, which
      # hid the room number and the sheet's own colouring.
      MARK_SHAPES = { 'hunting' => 'outline', 'creature' => 'outline', 'hunting_room_id' => 'ring', 'hunting_boundaries' => 'cross',
                      'rallypoint_room_ids' => 'ring', 'field_rest_room_id' => 'box', 'resting_room_id' => 'box' }.freeze

      # Where the map sheets are served from, set by the launcher once it has
      # registered Lich's map directory, or nil when it could not. With no
      # route the rooms still draw and click; only the artwork is missing.
      def map_route = @map_route

      # @param route [String, nil]
      def map_route=(route)
        @map_route = route
      end

      # Where the sheet files are on disk, for their sizes; nil when not here.
      def map_dir = @map_dir

      # @param dir [String, nil]
      def map_dir=(dir)
        @map_dir = dir
      end

      # The map under its heading, which folds it.
      def area_map(ui, editor, session)
        open = editor.map_open?
        Page.section_heading(ui, 'map', 'Map', session, open: open, toggle: :toggle_map)
        return unless open

        current = editor.map
        ui.stack(key: 'map', gap: 6) do
          if current.nil?
            ui.text(key: 'unavailable', tone: :caution, content: editor.map_error || 'The installed map is unavailable.')
            next
          end
          Array(current[:diagnostics]).each_with_index do |note, index|
            ui.text(key: "d#{index}", tone: :caution, content: note.to_s)
          end
          editor.keep_sheet(Page.current_sheet(editor, current))
          Page.map_finder(ui, editor, session)
          Page.map_controls(ui, editor, current, session)
          ui.text(key: 'legend', emphasis: :subtle,
                  content: 'Left-click a room to give it the chosen role; right-click clears it. ' \
                           'Green outline: the hunt. Teal outline: where the picked creature lives, and where the start room goes. ' \
                           'Blue ring: start. Red cross: boundary. Orange ring: rally. ' \
                           'Purple box: field rest. Pink box: town rest. ' \
                           'Drag to pan; Ctrl and the wheel zooms. The view stays put while you click.')
          ui.scroll(key: 'view', max_height: editor.map_view_height) do
            Page.map_surface(ui, editor, current, session)
          end
          Page.map_status(ui, editor, current)
          Page.footprint_controls(ui, editor, current, session)
        end
      end

      # Find where to look: a box that fills in place names as they are
      # typed, and takes part of a room title, a room id or a UID as well.
      # When the finds are spread over sheets, a second box offers them.
      def map_finder(ui, editor, session)
        places = editor.area_names.map { |entry| entry[:name].to_s }.reject(&:empty?).first(BOUNDS_OPTIONS - 1)
        options = [{ value: '', label: '' }] + places.map { |name| { value: name, label: name } }
        matches = editor.room_matches
        ui.columns(key: 'finder', count: 2, weights: [0, 1], compact: true, row_align: :end) do
          ui.select(slot: '0', key: 'find', label: 'Find', editable: true, options: options, control_width_chars: 34,
                    value: editor.room_query,
                    placeholder: 'a place, part of a room title, a room id or uNNNN',
                    tooltip: 'Place names fill in as you type. Anything else is looked for in room titles. ' \
                             'The sheet it is on comes up with that room in view.',
                    on: { change: Page.on(session, :find_room) })
          choices = editor.sheet_choices
          if matches.empty? && choices.size > 1
            # A found creature living on several sheets: which to show.
            ui.select(slot: '1', key: 'found-sheets', label: "#{choices.size} sheets",
                      options: [{ value: '', label: 'pick one' }] + choices.map { |sheet| { value: sheet[:id].to_s, label: sheet[:name].to_s } },
                      value: '', tooltip: "The sheets #{editor.room_query} lives on. Pick one to show it.",
                      on: { change: Page.on(session, :sheet) })
          elsif !matches.empty?
            ui.select(slot: '1', key: 'found', label: "#{matches.size} rooms found",
                      options: [{ value: '', label: 'pick one' }] + matches.map do |room|
                        { value: room[:id].to_s, label: "#{room[:title]} (#{room[:id]}) - #{room[:sheet_label] || room[:image]}" }
                      end,
                      value: '', tooltip: 'Which of the finds to show',
                      on: { change: Page.on(session, :go_to_room) })
          end
        end
      end

      # How many options a select may hold, by the contract.
      BOUNDS_OPTIONS = 512

      # The sheet, the role a click assigns, and the zoom.
      def map_controls(ui, editor, current, session)
        ui.columns(key: 'controls', count: 5, weights: [0, 0, 0, 0, 0], compact: true, row_align: :end) do
          # The sheets the hunt touches first, with their room counts, then
          # every other installed sheet: an empty hunt starts by picking one.
          counts = Page.sheet_counts(current)
          labels = current[:sheet_labels] || {}
          options = counts.sort_by { |name, count| [-count, name] }.map do |name, count|
            { value: name, label: "#{labels[name] || name} (#{count} rooms)" }
          end
          shown = Page.current_sheet(editor, current).to_s
          others = (Array(current[:sheets]) + [shown]).uniq.reject { |name| name.empty? || counts.key?(name) }
          others = others.sort_by { |name| (labels[name] || name).downcase }
          options.concat(others.map { |name| { value: name, label: labels[name] || name } })
          options.unshift(value: '', label: 'Pick a sheet') if counts.empty?
          options = [{ value: '', label: '(no sheets installed)' }] if options.empty?
          # A new select whenever the sheet changes, as the boxes the map
          # writes are new boxes: the browser then has no earlier choice of
          # its own to show over the sheet the finder just switched to.
          ui.select(slot: '0', key: "sheet-#{Digest::SHA256.hexdigest(shown)[0, 8]}", label: 'Sheet', options: options, control_width_chars: 24,
                    value: shown,
                    tooltip: 'Which map to mark rooms on. Sheets the hunt is already drawn on come first.',
                    on: { change: Page.on(session, :sheet) })
          # Not the town rest: it is almost never on the hunting map. Its box
          # is on Rest.
          roles = Editor::ROLE_LABELS.reject { |role, _| %w[hunting creature resting_room_id].include?(role) }
                                     .map { |role, label| { value: role, label: label } }
          ui.select(slot: '1', key: 'role', label: 'Left-click sets', options: roles, value: editor.assign_role,
                    tooltip: 'What a left-click on a room makes it. A right-click clears a room whatever it is.',
                    on: { change: Page.on(session, :assign_role) })
          ui.button(slot: '2', key: 'zoom-out', label: '-', tooltip: 'Zoom out', on: { activate: Page.on(session, :map_zoom, 'out') })
          ui.button(slot: '3', key: 'zoom-reset', label: "#{(editor.map_scale * 100).round}%", tooltip: 'Back to the sheet fitting the width',
                    on: { activate: Page.on(session, :map_reset_zoom) })
          ui.button(slot: '4', key: 'zoom-in', label: '+', tooltip: 'Zoom in', on: { activate: Page.on(session, :map_zoom, 'in') })
        end
      end

      # How many of the map's rooms are drawn on each sheet.
      def sheet_counts(current)
        counts = Hash.new(0)
        Array(current[:rooms]).each do |room|
          next unless room[:image_coords]

          name = room[:image].to_s
          counts[name] += 1 unless name.empty?
        end
        counts
      end

      # The sheet being looked at: the chosen one, else the one most of the
      # hunt's rooms are drawn on.
      def current_sheet(editor, current)
        return editor.sheet if editor.sheet && !editor.sheet.to_s.empty?

        Page.sheet_counts(current).max_by { |name, count| [count, name] }&.first
      end

      # The sheet image with one region per room on it, cropped to the hunt.
      def map_surface(ui, editor, current, session)
        sheet = Page.current_sheet(editor, current)
        rooms = Array(current[:rooms]).select { |room| room[:image].to_s == sheet.to_s && room[:image_coords] }
        if rooms.empty?
          ui.text(key: 'no-rooms', emphasis: :subtle, content: 'No rooms on this sheet carry map coordinates.')
          return
        end

        route = Page.map_route
        layers = []
        layers << { 'kind' => 'image', 'x' => 0, 'y' => 0, 'src' => "#{route}#{sheet}" } if route
        ui.text(key: 'no-art', tone: :caution, content: 'The map artwork is not being served; the rooms still work.') unless route
        lives = editor.fence_rooms
        # Only what means something is drawn: the marks. A click is a point
        # on the surface and Editor#room_at finds the room under it, as Lich's
        # map does, so the rooms cost no layers of their own.
        rooms.each do |room|
          role = editor.role_for(room[:id]) || ('creature' if lives.include?(room[:id]))
          layers.concat(Page.room_marks(role, room[:image_coords])) if role
        end
        # The whole sheet, every time: the marks are what is being edited,
        # so the view is never cut to them. The sheet's own size when its
        # file can be read, else the box its rooms occupy. Only the first
        # draw of a sheet scrolls to the start room; after that the view
        # stays where the viewer put it.
        marked = rooms.select { |room| editor.role_for(room[:id]) || lives.include?(room[:id]) }
        fresh = editor.map_frame.nil?
        frame = editor.map_frame ||= Page.sheet_frame(sheet, rooms)
        editor.map_origin = { x: frame[:x], y: frame[:y] }
        anchor = fresh ? (editor.take_map_anchor || Page.map_anchor(marked.empty? ? rooms : marked, editor)) : nil
        # The room the view opens on is the one region: scroll_to names one.
        # It takes no clicks; those go to the surface.
        if anchor && (room = rooms.find { |entry| entry[:id] == anchor })
          x1, y1, x2, y2 = room[:image_coords].map(&:to_i)
          layers << { 'kind' => 'region', 'key' => "room-#{anchor}", 'x1' => x1, 'y1' => y1, 'x2' => x2, 'y2' => y2, 'activates' => false }
        end
        layers = Page.shift_layers(layers, frame)
        surface = lambda do |key, chunk, first|
          ui.composite(key: key, width: frame[:width], height: frame[:height],
                       scale: Page.map_scale(frame, editor), surface_events: true, layers: chunk,
                       **(anchor && first ? { scroll_to: "room-#{anchor}" } : {}),
                       on: { surface_activate: Page.on(session, :map_click), zoom: Page.on(session, :map_wheel) })
        end
        # More marks than a composite takes: stacked composites over one
        # another, as Lich's map splits its overlays, so nothing is dropped.
        if layers.size <= MAP_LAYERS
          surface.call('surface', layers, true)
        else
          ui.overlay(key: 'surfaces') do
            layers.each_slice(MAP_LAYERS).with_index { |chunk, index| surface.call("surface-#{index}", chunk, index.zero?) }
          end
        end
      end

      # What the map shows, in a line.
      def map_status(ui, editor, current)
        hunting = Array(current[:hunting_room_ids]).size
        bounds = Array(current.dig(:markers, 'hunting_boundaries')).size
        start = editor.settings['hunting_room_id'].to_s
        parts = []
        parts << (start.empty? ? 'No start room yet.' : "Start room #{start}.")
        parts << "#{hunting} hunting room#{'s' if hunting != 1}, #{bounds} boundar#{bounds == 1 ? 'y' : 'ies'}."
        parts << 'The hunt was cut short at the walker\'s limit.' if current[:truncated]
        ui.text(key: 'map-status', content: parts.join(' '), emphasis: :subtle)
      end

      # Recompute the boundaries from the rooms the hunt covers now.
      def footprint_controls(ui, editor, current, session)
        rooms = Array(current[:hunting_room_ids])
        start = editor.settings['hunting_room_id'].to_s
        return if rooms.empty? || start.empty?

        ui.button(key: 'refit', label: "Recompute boundaries for these #{rooms.size} rooms",
                  tooltip: 'Refuses rather than widening the area if these rooms cannot form one reachable hunt from the start.',
                  on: { activate: Page.on(session, :room_geometry, rooms, start.to_i) })
      end

      # The layers that show a room's role: a wash for the hunt's rooms, a
      # mark for the rooms worth finding.
      def room_marks(role, box)
        x1, y1, x2, y2 = box.map(&:to_i)
        left = [x1, x2].min
        top = [y1, y2].min
        width = (x2 - x1).abs
        height = (y2 - y1).abs
        colour = Editor::ROLE_COLOURS.fetch(role)
        shape = MARK_SHAPES.fetch(role)
        case shape
        when 'outline'
          # A thin outline, not a wash: the room keeps its number and its
          # own colour, which the sheets use to say what kind of room it is.
          [{ 'kind' => 'rectangle', 'mode' => 'stroke', 'x' => left, 'y' => top, 'w' => width, 'h' => height,
             'color' => colour, 'line_width' => 3 }]
        when 'box'
          [{ 'kind' => 'rectangle', 'mode' => 'stroke', 'x' => left, 'y' => top, 'w' => width, 'h' => height,
             'color' => colour, 'line_width' => 4 }]
        else
          inset_x = [(width * MARK_INSET).round, 1].max
          inset_y = [(height * MARK_INSET).round, 1].max
          [{ 'kind' => 'marker', 'shape' => shape, 'x' => left + inset_x, 'y' => top + inset_y,
             'w' => [width - (2 * inset_x), 2].max, 'h' => [height - (2 * inset_y), 2].max,
             'line_width' => 3, 'color' => colour }]
        end
      end

      # The whole sheet: its image's own size, read from the file's header
      # when the sheets are on disk here, else the box its rooms occupy.
      def sheet_frame(sheet, rooms)
        size = Page.sheet_size(sheet)
        return { x: 0, y: 0, width: size[0], height: size[1] } if size

        box = Page.map_frame(rooms)
        { x: 0, y: 0, width: box[:x] + box[:width], height: box[:y] + box[:height] }
      end

      # The first bytes of a PNG and of a JPEG, built rather than written so
      # the source stays ASCII.
      PNG_SIGNATURE = [0x89].pack('C') + 'PNG'.b
      JPEG_SIGNATURE = [0xFF, 0xD8].pack('C2')

      # A sheet image's pixel size from its header: PNG, GIF or JPEG.
      # @return [Array(Integer, Integer), nil] width and height, or nil when
      #   the file is not there or not one of those
      def sheet_size(sheet)
        return nil if Page.map_dir.to_s.empty? || sheet.to_s.empty?

        path = File.join(Page.map_dir, sheet.to_s)
        return nil unless File.file?(path)

        File.open(path, 'rb') do |file|
          head = file.read(26).to_s
          if head.start_with?(PNG_SIGNATURE)
            return head[16, 8].unpack('N2')
          elsif head.start_with?('GIF'.b)
            return head[6, 4].unpack('v2')
          elsif head.start_with?(JPEG_SIGNATURE)
            return Page.jpeg_size(file)
          end
        end
        nil
      rescue SystemCallError
        nil
      end

      # Walk a JPEG's segments to the first frame header, which carries
      # the size.
      def jpeg_size(file)
        file.seek(2)
        while (marker = file.read(2)) && marker.bytesize == 2
          return nil unless marker.getbyte(0) == 0xFF

          kind = marker.getbyte(1)
          next if kind == 0xFF
          length = file.read(2).to_s.unpack1('n')
          return nil if length.nil? || length < 2

          if (0xC0..0xCF).cover?(kind) && ![0xC4, 0xC8, 0xCC].include?(kind)
            body = file.read(5).to_s
            return nil if body.bytesize < 5

            height, width = body[1, 4].unpack('n2')
            return [width, height]
          end
          file.seek(length - 2, IO::SEEK_CUR)
        end
        nil
      end

      # The box the rooms occupy, padded and squared off so the fit fills
      # the view both ways.
      def map_frame(rooms)
        boxes = rooms.filter_map { |room| room[:image_coords] }
        return { x: 0, y: 0, width: 1200, height: 900 } if boxes.empty?

        x1 = boxes.map { |box| [box[0].to_i, box[2].to_i].min }.min
        y1 = boxes.map { |box| [box[1].to_i, box[3].to_i].min }.min
        x2 = boxes.map { |box| [box[0].to_i, box[2].to_i].max }.max
        y2 = boxes.map { |box| [box[1].to_i, box[3].to_i].max }.max
        pad = [[(x2 - x1), (y2 - y1)].max * MAP_CONTEXT_SHARE, MAP_PADDING].max
        pad = [pad, MAP_CONTEXT_MAX].min.round
        left = [x1 - pad, 0].max
        top = [y1 - pad, 0].max
        width = [(x2 + pad) - left, 120].max
        height = [(y2 + pad) - top, 120].max
        side = [width, height].max
        left = [left - ((side - width) / 2), 0].max
        top = [top - ((side - height) / 2), 0].max
        { x: left, y: top, width: side, height: side }
      end

      # Move every layer so the frame's top-left is the surface's origin.
      # The sheet image moves with them, which is what crops it.
      def shift_layers(layers, frame)
        dx = frame[:x]
        dy = frame[:y]
        return layers if dx.zero? && dy.zero?

        layers.map do |layer|
          moved = layer.dup
          %w[x x1 x2].each { |key| moved[key] = layer[key] - dx if layer.key?(key) }
          %w[y y1 y2].each { |key| moved[key] = layer[key] - dy if layer.key?(key) }
          moved
        end
      end

      # How far to scale the surface so the sheet fills the view's width,
      # times the viewer's own zoom. Rounded down: a surface a fraction wider
      # than its view is a clipped edge.
      def map_scale(frame, editor)
        width = frame[:width].to_f
        fit = width.positive? ? editor.map_fit_width / width : 1.0
        (((fit * editor.map_scale) * 1000).floor / 1000.0).clamp(0.1, 8.0)
      end

      # The room the view opens looking at: the start room, else the marked
      # room nearest the middle of them all.
      def map_anchor(rooms, editor)
        ids = rooms.map { |room| room[:id] }
        start = ids.find { |id| editor.role_for(id) == 'hunting_room_id' }
        return start if start

        boxes = rooms.filter_map { |room| room[:image_coords] && [room[:id], room[:image_coords]] }
        return ids.first if boxes.empty?

        cx = boxes.sum { |(_id, box)| (box[0].to_i + box[2].to_i) / 2.0 } / boxes.size
        cy = boxes.sum { |(_id, box)| (box[1].to_i + box[3].to_i) / 2.0 } / boxes.size
        boxes.min_by do |(_id, box)|
          (((box[0].to_i + box[2].to_i) / 2.0) - cx)**2 + (((box[1].to_i + box[3].to_i) / 2.0) - cy)**2
        end&.first
      end

      # --- Helpers the editor and the session share ---------------------------

      # A component key for a named row, safe for the contract and stable
      # across renders. Unsafe characters become '_', and a short digest keeps
      # two names that differ only in those characters apart.
      # @param prefix [String] which list the row is in
      # @param name [String] the row's name
      # @return [String]
      def row_key(prefix, name)
        text = name.to_s
        safe = text.gsub(/[^A-Za-z0-9_.:-]/, '_')
        digest = Digest::SHA256.hexdigest(text)[0, 8]
        "#{prefix}-#{safe}-#{digest}"[0, 128]
      end

      # The name a row key was made from, out of the names offered.
      # @param prefix [String] the list's prefix
      # @param key [String] the activated row's key
      # @param names [Array<String>] what the list holds
      # @return [String, nil]
      def row_name(prefix, key, names)
        names.find { |name| Page.row_key(prefix, name) == key.to_s }
      end

      # What a list setting can be filled with: the chosen area's creatures,
      # for the settings that take creature names.
      # @param editor [Editor] the editing session
      # @param field [Hash] a schema field descriptor
      # @return [Array<String>]
      def list_suggestions(editor, field)
        return [] unless CREATURE_LISTS.include?(field['key'])

        editor.respond_to?(:area_creatures) ? editor.area_creatures.map { |creature| creature[:name].to_s } : []
      end

      # A select's options from a list of names, with an unset entry first.
      def name_options(names, unset_label)
        [{ value: '', label: unset_label }] + names.map(&:to_s).reject(&:empty?).uniq.map { |name| { value: name, label: name } }
      end

      # The hand and ammunition pickers' options. The contract refuses a
      # select whose options repeat a value, so they are deduplicated, and
      # the group each came from is shown in its label.
      def equipment_options(records)
        seen = {}
        options = [{ value: '', label: '(unset)' }]
        Array(records).each do |record|
          value = (record['value'] || record[:value]).to_s
          next if value.empty? || value == OTHER || seen[value]

          seen[value] = true
          label = (record['label'] || record[:label] || value).to_s
          group = (record['group'] || record[:group]).to_s
          options << { value: value, label: group.empty? ? label : "#{label}  [#{group}]" }
        end
        options
      end

      # How tall a text box is for its text: two lines when empty, growing
      # with what is in it.
      def rows_for(text)
        (text.to_s.lines.size + 1).clamp(2, 14)
      end

      # Run a Ruby condition where the hunt would and say what it said, in a
      # line. Parsed first, as Validate does: Ruby's own SyntaxError is a
      # multi-line source excerpt that will not fit on one.
      #
      # Off the caller's thread with a time limit: the condition is arbitrary
      # code, and one that waits on the game must not freeze the window.
      # @param code [String] the condition
      # @param evaluate [#call] runs the code where the hunt would
      # @return [String]
      def test_condition(code, evaluate)
        return 'Nothing to test.' if code.to_s.strip.empty?

        require 'prism'
        broken = Prism.parse(code).errors.first
        return "Not valid Ruby: #{broken.message}" if broken

        outcome = nil
        worker = Thread.new do
          value = evaluate.call(code)
          outcome = "#{value ? 'true' : 'false'} right now (#{value.inspect[0, 80]})"
        rescue Exception => error # rubocop:disable Lint/RescueException -- a SyntaxError or a script exit must be shown, not kill the page
          outcome = "Raised #{error.class}: #{error.message[0, 200]}"
        end
        return outcome if worker.join(TEST_LIMIT)

        worker.kill
        "Did not finish within #{TEST_LIMIT} seconds; stopped."
      end
    end
  end
end
