# frozen_string_literal: true

module EO
  module HunterSetup
    # One run of the editor: reads what the character has, opens the page
    # in Lich's WebUI and waits for it to close.
    #
    # The only part of setup that reaches into Lich. Everything it reads is
    # captured here and handed to Runtime.app, so the rest stays testable
    # without a game.
    module Launch
      # Weapon categories a character cannot pick up and hold: `natural` is
      # bite, claw, pincer and stinger. Excluded rather than the others
      # listed, so a category added to Lich later is offered by default.
      NON_ITEM_CATEGORIES = %i[natural].freeze

      # The page's identity within the script that owns it.
      PAGE_ID = 'eohunter-setup'

      module_function

      # Open the editor and block until the viewer closes it.
      #
      # @param script_dir [String] Lich script directory
      # @param context [Binding] where the hunt evaluates its Ruby conditions
      #   (eohunter.lic's top level), so Test now runs them the same way
      # @return [void]
      def run(script_dir:, context:) # rubocop:disable Lint/UnusedMethodArgument -- the directory names the install; nothing is loaded from it any more
        unless defined?(Lich::WebUI) && Lich::WebUI.respond_to?(:presentation_enabled?)
          raise 'the editor needs a Lich with the WebUI; update Lich'
        end
        raise 'the editor needs the WebUI, and this Lich was started with --no-gui' unless Lich::WebUI.presentation_enabled?

        owner = Script.current
        editor = Editor.new(app: app)
        closed = Queue.new
        page = nil
        session = Session.new(
          editor: editor,
          evaluate: ->(code) { eval(code, context) }, # -- Test now, on the viewer's own condition
          # The window's measured size goes with every redraw, so the map
          # fits the width the viewer actually has.
          refresh: lambda {
            next unless page

            editor.window_size = page.window_geometry&.slice(:width, :height)
            Lich::API.webui_refresh(page)
          },
          confirm: ->(what, &change) { confirm(owner, what, &change) }
        )
        Page.map_route = serve_maps(owner)
        # The window closes with this script: the page is owned by it, so
        # killing the script tears the page down without a handler here.
        page = Lich::API.webui_page(
          owner: owner, id: PAGE_ID, title: "eohunter setup - #{Char.name}",
          # Not density: :compact. The client lays every tabs component out
          # as a column in that density, which puts the vertical rail's
          # panel underneath it instead of beside it.
          props: { size: Page::WINDOW_SIZE },
          on: { close: proc { closed << true } }
        ) { |ui| Page.render(ui, editor, session) }
        Lich::API.webui_refresh(page)
        Lich::API.webui_start
        unless Lich::API.webui_open(page: page)
          # An app-mode window needs Chrome or Edge; without one the URL opens
          # anywhere. It is single-use, so it is printed and not kept.
          Lich::Messaging.msg('info', "eohunter setup: open #{Lich::API.webui_launch_url(page: page)} in a browser")
        end
        # Now that the editor is on screen, ask the game for what Lich did not
        # already know. Both of these block -- the ready list waits out
        # roundtime and a reply, the inventory up to five seconds -- which is
        # why they run after the page is open rather than before.
        editor.equipment = read_equipment
        editor.window_size = page.window_geometry&.slice(:width, :height)
        Lich::API.webui_refresh(page)
        closed.pop
      ensure
        Lich::WebUI.close(page) if page
      end

      # Serve Lich's map sheets to the page. The directory has to sit inside
      # a registered root, and naming it as its own script root is what lets
      # the installed maps serve without a Lich change. A map that cannot
      # be served is no reason to refuse the editor: with no route the page
      # draws the rooms without the artwork.
      # @param owner [Object] the script that owns the page
      # @return [String, nil] the URL prefix the sheets are served under
      def serve_maps(owner)
        return nil unless defined?(MAP_DIR) && File.directory?(MAP_DIR.to_s)

        Page.map_dir = MAP_DIR
        Lich::WebUI.service.register_files('eohunter-maps', MAP_DIR, owner: owner, script_root: MAP_DIR)
      rescue StandardError => error
        Lich::Messaging.msg('warn', "eohunter setup: installed maps unavailable (#{error.message})")
        nil
      end

      # Ask before edits are thrown away. The answer arrives later, on the
      # page's own queue, so the change is run from the modal's callback
      # rather than awaited here.
      # @param owner [Object] the script that owns the page
      # @param what [String] what is about to happen
      # @yield [agreed] true once the viewer chooses to discard the edits,
      #   false when they keep editing or the dialog went unanswered
      # @return [void]
      def confirm(owner, what, &change)
        @confirm_serial = @confirm_serial.to_i + 1
        future = Lich::API.webui_modal(
          owner: owner, id: "#{PAGE_ID}-confirm-#{@confirm_serial}", title: 'Unsaved changes',
          body: "#{what} and lose the unsaved changes?",
          buttons: [{ id: 'discard', label: 'Discard the changes', variant: :danger },
                    { id: 'keep', label: 'Keep editing' }],
          no_viewer: :abort, default_button: 'keep'
        )
        future.then { |result| change.call(result.button == 'discard') }
      end

      # @return [App] editor operations bound to this character
      def app
        Runtime.app(
          data_dir: DATA_DIR, game: XMLData.game, character: Char.name,
          templates: templates,
          rooms: Map.list, uid_resolver: ->(uid) { Map.ids_from_uid(uid) },
          # The creature finder opens on a band around the character's level.
          level: (XMLData.level.to_i rescue 0),
          ready_list: ready_list,
          inventory: inventory,
          armaments: armaments,
          scripts: scripts
        )
      end

      # What the character has readied and carries, asked of the game.
      # @return [Hash] ready_list and inventory
      def read_equipment
        begin
          Lich::Gemstone::ReadyList.check(silent: true, quiet: true) unless Lich::Gemstone::ReadyList.checked?
        rescue StandardError => error
          Lich::Messaging.msg('warn', "eohunter setup: could not read your ready list (#{error.message})")
        end
        begin
          Lich::Common::Inventory.refresh
        rescue StandardError => error
          Lich::Messaging.msg('warn', "eohunter setup: could not read your inventory (#{error.message})")
        end
        { ready_list: ready_list, inventory: inventory }
      end

      # Installed script names, from where Lich looks for them: the scripts
      # directory, custom/, and each directory under custom/.
      def scripts
        dirs = [SCRIPT_DIR, File.join(SCRIPT_DIR, 'custom')] + Dir.glob(File.join(SCRIPT_DIR, 'custom', '*/'))
        dirs.flat_map { |dir| Dir.glob(File.join(dir, '*.{lic,rb,cmd,wiz}')) }
            .map { |path| File.basename(path, '.*') }.uniq
      rescue StandardError
        nil
      end

      # Lich namespaces this as Lich::Gemstone::CreatureTemplate; testing the
      # short name alone would hand the editor an empty creature list.
      def templates
        if defined?(Lich::Gemstone::CreatureTemplate)
          Lich::Gemstone::CreatureTemplate.all
        elsif defined?(CreatureTemplate)
          CreatureTemplate.all
        else
          []
        end
      end

      # What the character has readied, from what Lich already knows. Asking
      # the game would block the editor on roundtime and a reply, and an
      # unchecked list reports stale entries, so it is passed as empty
      # rather than believed.
      def ready_list
        list = Lich::Gemstone::ReadyList
        list.checked? ? list.ready_list.transform_keys(&:to_s) : {}
      rescue StandardError
        {}
      end

      # What the character carries. `GameObj.inv` holds the containers worn,
      # not what is in them, so the contents come from the inventory
      # snapshot when Lich has one.
      def inventory
        snapshot = Lich::Common::Inventory.current
        items = snapshot ? snapshot.all : (GameObj.inv.to_a + GameObj.containers.values.flatten)
        items.compact.map do |item|
          { noun: item.noun, name: item.name, types: item.type,
            container: item.respond_to?(:container?) ? item.container? : nil }
        end
      rescue StandardError
        []
      end

      # The words that make an item a weapon or a shield, from Lich's
      # armament tables: gameobj-data types almost nothing as a weapon and
      # has no shield type at all.
      def armaments
        stats = Lich::Gemstone::Armaments::WeaponStats
        categories = stats.categories - NON_ITEM_CATEGORIES
        {
          weapons: categories.flat_map { |category| stats.list(category) }
                             .flat_map { |weapon| Array(weapon[:all_names]) }
                             .compact.uniq,
          shields: Lich::Gemstone::Armaments::ShieldStats.names
        }
      rescue StandardError
        {}
      end
    end
  end
end
