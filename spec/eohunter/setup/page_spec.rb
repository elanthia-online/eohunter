# frozen_string_literal: true

require 'tmpdir'
require 'yaml'
require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

# A stand-in for Lich's TreeBuilder that records what the page draws: the
# tree of components, each with its type, props, slot and bound handlers.
# It enforces the parts of the contract the page is most likely to trip
# over -- a slot under a named parent, unique keys among siblings, keys
# inside a collection, a select value among its options -- so a render that
# passes here has a fair chance in the browser.
class RecordingBuilder
  Node = Struct.new(:type, :props, :slot, :on, :children, :cid, keyword_init: true)

  NAMED = { columns: ->(props) { Array.new(props[:count]) { |i| i.to_s } },
            tabs: ->(props) { props[:names] },
            split: ->(_props) { %w[first second] } }.freeze

  attr_reader :root

  def initialize
    @root = Node.new(type: :page, props: {}, on: {}, children: [], cid: 'page')
    @stack = [@root]
    @collection_depth = Hash.new(0)
  end

  def component(type, key: nil, slot: nil, on: {}, submit: nil, **props, &block) # rubocop:disable Lint/UnusedMethodArgument
    parent = @stack.last
    raise "#{type} inside a collection needs a key" if @collection_depth[parent].positive? && key.nil?

    segment = key || parent.children.count { |child| child.props[:key].nil? }
    cid = "#{parent.cid}/#{type}:#{segment}"
    raise "duplicate identity #{cid}" if parent.children.any? { |child| child.cid == cid }

    if (slots = NAMED[parent.type])
      names = slots.call(parent.props)
      raise "#{type} under #{parent.type} needs a slot" if slot.nil?
      raise "slot #{slot.inspect} is not one of #{names.inspect}" unless names.include?(slot.to_s)
      raise "slot #{slot} used twice under #{parent.cid}" if parent.children.any? { |child| child.slot == slot.to_s }
    end
    check(type, props)
    node = Node.new(type: type, props: props.merge(key: key).compact, slot: slot&.to_s, on: on, children: [], cid: cid)
    parent.children << node
    if block
      @stack << node
      block.call(node)
      @stack.pop
    end
    node
  end

  %i[stack columns grid tabs group expander split scroll divider text markdown button toggle checkbox radio
     text_input textarea number_input select table composite image].each do |type|
    define_method(type) { |**props, &block| component(type, **props, &block) }
  end

  def collection(items)
    parent = @stack.last
    @collection_depth[parent] += 1
    items.each_with_index { |item, index| yield item, index }
  ensure
    @collection_depth[parent] -= 1
  end

  # Every node, depth first.
  def all(node = @root, &block)
    return enum_for(:all, node) unless block

    yield node
    node.children.each { |child| all(child, &block) }
  end

  private

  REQUIRED = { text: %i[content], button: %i[label], checkbox: %i[label checked], toggle: %i[checked],
               text_input: %i[value], textarea: %i[value], select: %i[options], tabs: %i[names],
               columns: %i[count], expander: %i[label], split: %i[orientation],
               composite: %i[width height layers] }.freeze

  def check(type, props)
    Array(REQUIRED[type]).each { |name| raise "#{type} needs #{name}" unless props.key?(name) }
    return unless type == :select

    values = props[:options].map { |option| option[:value] }
    raise 'select options repeat a value' unless values.uniq == values
    return if props[:editable] || !props.key?(:value) || values.include?(props[:value])

    raise "select value #{props[:value].inspect} is not among its options"
  end
end

# What the browser hands a callback.
FakeEvent = Struct.new(:payload)

RSpec.describe EO::HunterSetup::Page do
  around do |example|
    Dir.mktmpdir('hunter-page') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:app) do
    EO::HunterSetup::Runtime.app(
      data_dir: @directory, game: 'GSIV', character: 'Example',
      templates: [], rooms: [], uid_resolver: ->(_uid) { [] },
      inventory: [{ noun: 'falchion', name: 'a steel falchion', types: nil }],
      armaments: { weapons: %w[falchion], shields: [] }
    )
  end
  let(:editor) { EO::HunterSetup::Editor.new(app: app) }
  let(:calls) { [] }
  let(:session) do
    EO::HunterSetup::Session.new(editor: editor, refresh: -> { calls << :refresh })
  end

  def render
    builder = RecordingBuilder.new
    described_class.render(builder, editor, session)
    builder
  end

  def nodes(builder, type)
    builder.all.select { |node| node.type == type }
  end

  it 'draws the full editor with a tab for every page and a control for every setting' do
    # The boon settings show only when relevant; a value makes them so.
    # The aiming orders show when asked for.
    editor.on_change('boons_flee', 'regen')
    editor.on_toggle_aiming
    builder = render
    tabs = nodes(builder, :tabs).first
    expect(tabs.props[:names]).to eq(described_class::PAGES.map { |item| item[:label] })
    expect(tabs.props[:selected]).to eq(0)
    # Only the page being looked at is drawn, so every page is looked at in
    # turn. A box the map writes carries its value in its key; the setting's
    # key is what comes before that.
    keyed = described_class::PAGES.each_index.flat_map do |index|
      tabs.on[:select].call(FakeEvent.new({ index: index }))
      expect(editor.page_index).to eq(index)
      render.all.map { |node| node.props[:key]&.to_s&.sub(/-\h{8}\z/, '') }.compact
    end
    editor.fields.each do |field|
      expect(keyed).to include(field['key']), "no control for #{field['key']}"
    end
  end

  it 'binds only handlers the session has' do
    bound = render.all.flat_map { |node| node.on.values }
    expect(bound).not_to be_empty
    bound.each do |handler|
      expect { handler.call(FakeEvent.new({ value: '', row: 'none' })) }.not_to raise_error
    end
  end

  describe 'the creature search' do
    before do
      editor.on_show_page('area')
      editor.on_toggle_creature_search
    end

    # A creature template with only what the finder reads; everything else
    # answers nil, as an uncatalogued trait does.
    let(:template_class) do
      Struct.new(:name, :level, :family, :type, :areas, :undead, keyword_init: true) do
        def method_missing(_name, *_args) = nil
        def respond_to_missing?(_name, _private = false) = true
      end
    end

    let(:app) do
      EO::HunterSetup::Runtime.app(
        data_dir: @directory, game: 'GSIV', character: 'Example', level: 20,
        templates: [template_class.new(name: 'kobold', level: 1, family: 'kobold', type: 'biped', areas: [{ name: 'Kobold Warren', uids: [1] }]),
                    template_class.new(name: 'rolton', level: 18, family: 'rolton', type: 'quadruped', areas: [{ name: 'Upper Trollfang', uids: [2] }]),
                    template_class.new(name: 'troll', level: 22, family: 'troll', type: 'biped',
                                       areas: [{ name: 'Upper Trollfang', uids: [3] }, { name: 'Lower Trollfang', uids: [5] }]),
                    template_class.new(name: 'wraith', level: 60, family: 'undead', type: 'undead', undead: true,
                                       areas: [{ name: 'Upper Trollfang', uids: [4] }])],
        rooms: [], uid_resolver: ->(_uid) { [] }
      )
    end

    it 'opens on a band around the character and lists what is in it' do
      expect(editor.hunt_query).to include(low: 10, high: 35)
      list = nodes(render, :table).find { |node| node.props[:key] == 'list' }
      expect(list.props[:rows].map { |row| row[:cells]['name'] }).to eq(%w[rolton troll])
    end

    it 'widens the band from the inputs' do
      low = nodes(render, :number_input).find { |node| node.props[:key] == 'low' }
      low.on[:change].call(FakeEvent.new({ value: 1 }))
      names = nodes(render, :table).find { |node| node.props[:key] == 'list' }.props[:rows].map { |row| row[:cells]['name'] }
      expect(names).to eq(%w[kobold rolton troll])
    end

    it 'narrows by undead, type and family from the selects, and clears again' do
      editor.on_hunt_filter(:low, 1)
      editor.on_hunt_filter(:high, 100)
      names = -> { nodes(render, :table).find { |node| node.props[:key] == 'list' }.props[:rows].map { |row| row[:cells]['name'] } }
      undead = nodes(render, :select).find { |node| node.props[:key] == 'undead' }
      undead.on[:change].call(FakeEvent.new({ value: 'yes' }))
      expect(names.call).to eq(%w[wraith])
      undead.on[:change].call(FakeEvent.new({ value: 'no' }))
      expect(names.call).to eq(%w[kobold rolton troll])
      undead.on[:change].call(FakeEvent.new({ value: '' }))
      type = nodes(render, :select).find { |node| node.props[:key] == 'types' }
      expect(type.props[:options].map { |option| option[:value] }).to include('biped', 'quadruped', 'undead')
      type.on[:change].call(FakeEvent.new({ value: 'biped' }))
      expect(names.call).to eq(%w[kobold troll])
      type.on[:change].call(FakeEvent.new({ value: '' }))
      family = nodes(render, :select).find { |node| node.props[:key] == 'families' }
      family.on[:change].call(FakeEvent.new({ value: 'rolton' }))
      expect(names.call).to eq(%w[rolton])
      sleepable = nodes(render, :select).find { |node| node.props[:key] == 'sleepable' }
      expect(sleepable.props[:tooltip]).to include('1 not recorded')
    end
  end

  it 'hands a checkbox value through as a boolean and text through the form parser' do
    editor.on_show_page('hunting')
    builder = render
    check = nodes(builder, :checkbox).first
    editor.on_show_page('area')
    builder = render
    check.on[:change].call(FakeEvent.new({ value: true }))
    expect(editor.settings[check.props[:key]]).to be(true)
    entry = nodes(builder, :text_input).find { |node| node.props[:key].start_with?('hunting_room_id') }
    entry.on[:change].call(FakeEvent.new({ value: '228' }))
    expect(editor.settings['hunting_room_id']).to eq('228')
  end

  it 'takes a list as comma-separated text' do
    editor.on_show_page('area')
    builder = render
    box = nodes(builder, :text_input).find { |node| node.props[:key].start_with?('hunting_boundaries') }
    box.on[:change].call(FakeEvent.new({ value: '228, ,229 , 228' }))
    expect(editor.list_entries('hunting_boundaries')).to eq(%w[228 229])
    after = nodes(render, :text_input).find { |node| node.props[:key].start_with?('hunting_boundaries') }
    expect(after.props[:value]).to eq('228, 229')
    # A box the map writes to is a new box whenever its value changes, so
    # the browser has no typed draft to put back over what the map set. A
    # box the map never touches keeps one identity.
    expect(after.props[:key]).not_to eq(box.props[:key])
    editor.on_show_page('preparations')
    expect(nodes(render, :text_input).find { |node| node.props[:key] == 'hunting_scripts' }).not_to be_nil
  end

  it 'shows validation messages beside the setting they are about' do
    editor.on_show_page('hunting')
    editor.on_change('hunting_stance', 'sideways')
    editor.on_validate
    expect(editor.warnings.map { |entry| entry['key'] || entry[:key] }).to include('hunting_stance')
    builder = render
    row = nodes(builder, :stack).find { |node| node.props[:key] == 'f-hunting_stance' }
    expect(row.children.map(&:type)).to include(:text)
    expect(row.children.last.props[:tone]).to eq(:danger)
  end

  it 'offers the character equipment in an editable picker, deduplicated' do
    editor.on_show_page('equipment')
    builder = render
    hand = nodes(builder, :select).find { |node| node.props[:key] == 'hunting_right_hand' }
    expect(hand.props[:editable]).to be(true)
    values = hand.props[:options].map { |option| option[:value] }
    expect(values.grep(/falchion/)).not_to be_empty
    expect(values.uniq).to eq(values)
  end

  it 'lists the creatures in the hunt\'s rooms behind a button, each with a tick that hunts it or leaves it alone' do
    editor.on_show_page('creatures')
    allow(editor).to receive(:map).and_return({ hunting_room_ids: [1, 2], rooms: [], markers: {} })
    app = editor.instance_variable_get(:@app)
    allow(app).to receive(:call).and_wrap_original do |original, request|
      if request['action'] == 'creatures_here'
        expect(request['room_ids']).to eq([1, 2])
        [{ name: 'rolton', level: 5, undead: nil }, { name: 'kobold', level: 1, undead: nil }, { name: 'ghoul', level: 9, undead: true }]
      else
        original.call(request)
      end
    end
    expect(nodes(render, :button).map { |node| node.props[:key] }).to include('show-creatures')
    expect(nodes(render, :group).map { |node| node.props[:key] }).not_to include('here')
    editor.on_toggle_creatures
    builder = render
    ticks = nodes(builder, :checkbox).select { |node| node.props[:key] == 'hunt' }
    expect(ticks.map { |node| node.props[:label] }).to eq(%w[kobold rolton ghoul])
    expect(nodes(builder, :text).find { |node| node.props[:key] == 'about' && node.cid.include?('ghoul') }.props[:content]).to eq('level 9, undead')
    ticks[0].on[:change].call(FakeEvent.new({ value: true }))
    ticks[1].on[:change].call(FakeEvent.new({ value: false }))
    expect(editor.list_entries('targets')).to eq(['kobold'])
    expect(editor.list_entries('invalid_targets')).to eq(['rolton'])
    # Changing a mind moves it from one list to the other.
    ticks[1].on[:change].call(FakeEvent.new({ value: true }))
    expect(editor.list_entries('targets')).to eq(%w[kobold rolton])
    expect(editor.list_entries('invalid_targets')).to be_empty
    # A target with a marker still counts as listed.
    editor.on_change('targets', 'kobold(b), rolton')
    expect(nodes(render, :checkbox).select { |node| node.props[:key] == 'hunt' }.map { |node| node.props[:checked] }).to eq([true, true, false])
    # The Creatures to hunt box reads like its neighbours, stays a one-line
    # box however long it gets, and is a new box whenever its value changes.
    box = nodes(render, :text_input).find { |node| node.props[:key].start_with?('targets') }
    expect(box.props[:placeholder]).to eq('comma separated')
    expect(box.props[:key]).not_to eq('targets')
    editor.on_change('targets', ('a very long creature name, ' * 12).strip)
    expect(nodes(render, :text_input).find { |node| node.props[:key].start_with?('targets') }).not_to be_nil
    expect(nodes(render, :textarea).find { |node| node.props[:key].to_s.start_with?('targets') }).to be_nil
    # Hunt all of these: everything here into Creatures to hunt, nothing left
    # in Creatures to ignore.
    editor.on_change('targets', '')
    editor.on_change('invalid_targets', 'ghoul')
    nodes(render, :button).find { |node| node.props[:key] == 'hunt-all' }.on[:activate].call(FakeEvent.new({}))
    expect(editor.list_entries('targets')).to eq(%w[kobold rolton ghoul])
    expect(editor.list_entries('invalid_targets')).to be_empty
  end

  it 'keeps the boon settings out of the way until a boss-type creature is in the rooms or a box says something' do
    editor.on_show_page('creatures')
    allow(editor).to receive(:creatures_here).and_return([{ name: 'rolton', level: 5 }])
    builder = render
    keys = builder.all.map { |node| node.props[:key]&.to_s&.sub(/-\h{8}\z/, '') }
    expect(keys).not_to include('boons_ignore', 'boons_flee', 'show-boons_ignore')
    expect(nodes(builder, :text).find { |node| node.props[:key] == 'no-boons' }.props[:content]).to include('No boss-type creatures')
    # One boss type is enough.
    allow(editor).to receive(:creatures_here).and_return([{ name: 'rolton', level: 5 }, { name: 'warlord', level: 40, boss_type: 'miniboss' }])
    keys = render.all.map { |node| node.props[:key]&.to_s&.sub(/-\h{8}\z/, '') }
    expect(keys).to include('boons_ignore', 'boons_flee', 'show-boons_ignore')
    # So is a box that already says something, boss or no boss.
    allow(editor).to receive(:creatures_here).and_return([])
    editor.on_change('boons_flee', 'regen')
    expect(render.all.map { |node| node.props[:key]&.to_s&.sub(/-\h{8}\z/, '') }).to include('boons_flee')
  end

  it 'offers every known boon under each boon box, with its ASSESS words and what it does' do
    editor.on_show_page('creatures')
    allow(editor).to receive(:creatures_here).and_return([{ name: 'warlord', level: 40, boss_type: 'boss' }])
    buttons = nodes(render, :button).map { |node| node.props[:key] }
    expect(buttons).to include('show-boons_ignore', 'show-boons_flee')
    expect(nodes(render, :group).map { |node| node.props[:key] }).not_to include('pick-boons_flee')
    editor.on_toggle_boons('boons_flee')
    builder = render
    ticks = nodes(builder, :checkbox).select { |node| node.props[:key] == 'tick' && node.cid.include?('pick-boons_flee') }
    expect(ticks.size).to eq(EO::Engine::Targets::BOON_ADJECTIVES.size)
    regen = ticks.find { |node| node.props[:label] == 'Regen' }
    expect(nodes(builder, :text).find { |node| node.props[:key] == 'what' && node.cid.include?('regen') }.props[:content])
      .to start_with('slimy, muculent. Heals over time')
    regen.on[:change].call(FakeEvent.new({ value: true }))
    expect(editor.list_entries('boons_flee')).to eq(['regen'])
    expect(editor.list_entries('boons_ignore')).to be_empty
    expect(nodes(render, :checkbox).find { |node| node.props[:key] == 'tick' && node.props[:label] == 'Regen' }.props[:checked]).to be(true)
    regen.on[:change].call(FakeEvent.new({ value: false }))
    expect(editor.list_entries('boons_flee')).to be_empty
    # Every boon the reader knows has an effect line from the wiki page.
    expect(EO::HunterSetup::Schema::BOON_EFFECTS.keys).to match_array(EO::Engine::Targets::BOON_ADJECTIVES.keys)
  end

  it 'lists saved hunts one a line: the name opens it, Default ticks it, Delete asks about that one' do
    editor.on_rename('forest')
    editor.on_save
    editor.on_new
    editor.on_rename('plains')
    editor.on_save
    editor.on_new
    line = lambda do |builder, name|
      key = described_class.row_key('h', name)
      nodes(builder, :columns).find { |node| node.props[:key] == key }
    end
    within = ->(builder, name, type, key) { nodes(builder, type).find { |node| node.props[:key] == key && node.cid.include?(line[builder, name].cid) } }
    builder = render
    expect(nodes(builder, :table).map { |node| node.cid }).not_to include(a_string_including('saved'))
    expect(nodes(builder, :group).map { |node| node.props[:key] }).not_to include('confirm-delete')
    expect(nodes(builder, :select).map { |node| node.props[:key] }).not_to include('active')
    expect(%w[forest plains].map { |name| within[builder, name, :button, 'open'].props[:label] }).to eq(%w[forest plains])
    within[builder, 'forest', :button, 'open'].on[:activate].call(FakeEvent.new({}))
    expect(editor.name).to eq('forest')
    expect(editor.revision).to be_a(String)
    # Delete on the other line asks about that one, not the open one: the X
    # appears on that line only, and does the delete.
    within[builder, 'plains', :button, 'delete'].on[:activate].call(FakeEvent.new({}))
    expect(editor.pending_delete).to include(name: 'plains')
    builder = render
    expect(within[builder, 'plains', :button, 'confirm'].props[:variant]).to eq(:danger)
    expect(within[builder, 'forest', :button, 'confirm']).to be_nil
    # Delete again withdraws the ask.
    within[builder, 'plains', :button, 'delete'].on[:activate].call(FakeEvent.new({}))
    expect(editor.pending_delete).to be_nil
    within[render, 'plains', :button, 'delete'].on[:activate].call(FakeEvent.new({}))
    within[render, 'plains', :button, 'confirm'].on[:activate].call(FakeEvent.new({}))
    expect(editor.profiles).to eq(['forest'])
    # Default ticks the hunt a bare ;eohunter starts, and unticks to none.
    within[render, 'forest', :checkbox, 'default'].on[:change].call(FakeEvent.new({ value: true }))
    expect(editor.active_profile).to eq('forest')
    expect(within[render, 'forest', :checkbox, 'default'].props[:checked]).to be(true)
    within[render, 'forest', :checkbox, 'default'].on[:change].call(FakeEvent.new({ value: false }))
    expect(editor.active_profile).to be_nil
  end

  it 'asks before throwing away edits, and does not when there are none' do
    asked = []
    answer = false
    session = EO::HunterSetup::Session.new(editor: editor, refresh: -> { calls << :refresh },
                                           confirm: ->(what, &change) { asked << what; change.call(answer) })
    session.call(:new, FakeEvent.new({}))
    expect(asked).to be_empty
    editor.on_change('hunting_stance', 'offensive')
    calls.clear
    session.call(:new, FakeEvent.new({}))
    expect(asked).to eq(['Start a new hunt'])
    expect(editor.settings).to include('hunting_stance' => 'offensive')
    # Refusing still redraws, so a moved picker snaps back.
    expect(calls).to eq([:refresh])
    answer = true
    session.call(:new, FakeEvent.new({}))
    expect(editor.settings).not_to have_key('hunting_stance')
  end

  it 'refuses a handler name the page does not have' do
    expect { session.call(:no_such_thing, FakeEvent.new({})) }.to raise_error(ArgumentError, /no handler/)
  end

  it 'puts every setting of a page under a heading, and names only settings the page has' do
    described_class::GROUPS.each do |page, groups|
      fields = editor.fields_for(page)
      keys = fields.map { |field| field['key'] }
      groups.each do |(heading, members)|
        expect(keys).to include(*members), "#{page}: #{heading} names a setting the page does not have"
      end
      grouped = described_class.grouped(fields).flat_map { |(_heading, members)| members.map { |field| field['key'] } }
      expect(grouped).to match_array(keys)
    end
  end

  it 'pairs short controls two to a row and leaves tall ones alone' do
    editor.on_show_page('hunting')
    builder = render
    pair = nodes(builder, :columns).find { |node| node.props[:key] == 'r-hunting_stance' }
    expect(pair.children.map { |child| child.props[:key] }).to eq(%w[f-hunting_stance f-wander_stance])
    expect(pair.children.map(&:slot)).to eq(%w[0 1])
    list = described_class::PAGES.lazy.map do |item|
      editor.on_show_page(item[:id])
      nodes(render, :stack).find { |node| node.props[:key] == 'f-hunting_commands' }
    end.find(&:itself)
    expect(list.slot).to be_nil
  end

  describe 'the Combat routines page' do
    before { editor.on_show_page('combat') }

    it 'lists every routine as one lettered list with Quick and Fried last' do
      editor.on_change('hunting_commands_b', 'kick, punch')
      builder = render
      routines = nodes(builder, :group).find { |node| node.props[:key] == 'routines' }
      expect(routines.props[:label]).to eq('Routines')
      rows = nodes(builder, :stack).select { |node| node.props[:key].to_s.start_with?('f-') }
      expect(rows.map { |node| node.props[:key] }).to eq(
        %w[hunting_commands hunting_commands_b hunting_commands_c hunting_commands_d hunting_commands_e
           hunting_commands_f hunting_commands_g hunting_commands_h hunting_commands_i hunting_commands_j
           quick_commands disable_commands].map { |key| "f-#{key}" }
      )
      words = nodes(builder, :text).select { |node| node.props[:key].to_s.start_with?('w-') }.map { |node| node.props[:content] }
      expect(words).to eq(%w[a b c d e f g h i j Quick Fried])
      # One grid, so the words share a column and the boxes line up.
      grid = nodes(builder, :grid).find { |node| node.props[:key] == 'lettered' }
      expect(grid.props).to include(cols: 2, homogeneous: false, expand_columns: [2])
      expect(grid.children.size).to eq(24)
      box = nodes(builder, :text_input).find { |node| node.props[:key] == 'hunting_commands_b' }
      expect(box.props[:value]).to eq('kick, punch')
      expect(box.props[:label]).to be_nil
      box.on[:change].call(FakeEvent.new({ value: 'kick' }))
      expect(editor.list_entries('hunting_commands_b')).to eq(['kick'])
    end

    it 'keeps the aiming orders behind a button' do
      builder = render
      expect(nodes(builder, :group).map { |node| node.props[:key] }).not_to include('aiming')
      show = nodes(builder, :button).find { |node| node.props[:key] == 'show-aiming' }
      show.on[:activate].call(FakeEvent.new({}))
      builder = render
      aiming = nodes(builder, :group).find { |node| node.props[:key] == 'aiming' }
      expect(aiming.props[:label]).to eq('Aiming')
      words = nodes(builder, :text).select { |node| node.props[:key].to_s.start_with?('w-') }.map { |node| node.props[:content] }
      expect(words.last(3)).to eq(%w[Ambush Ranged Unarmed])
      expect(nodes(builder, :grid).count { |node| node.props[:key] == 'lettered' }).to eq(2)
      expect(nodes(builder, :text_input).map { |node| node.props[:key] }).to include('ambush', 'archery_aim', 'aim')
      nodes(builder, :button).find { |node| node.props[:key] == 'hide-aiming' }.on[:activate].call(FakeEvent.new({}))
      expect(nodes(render, :group).map { |node| node.props[:key] }).not_to include('aiming')
    end
  end

  describe 'the map' do
    # Three rooms on one sheet: a start, a boundary and a room in between.
    let(:rooms) do
      [{ id: 1, title: 'Gate', image: 'town.png', image_coords: [100, 100, 120, 120] },
       { id: 2, title: 'Path', image: 'town.png', image_coords: [140, 100, 160, 120] },
       { id: 3, title: 'Wall', image: 'town.png', image_coords: [180, 100, 200, 120] }]
    end
    # Markers follow the draft, as the real map's do.
    def current
      settings = editor.settings
      { markers: { 'hunting_room_id'    => settings['hunting_room_id'],
                   'hunting_boundaries' => editor.list_entries('hunting_boundaries').map(&:to_i),
                   'field_rest_room_id' => settings['field_rest_room_id'],
                   'resting_room_id'    => settings['resting_room_id'] },
        rooms: rooms, hunting_room_ids: [1, 2], sheets: ['town.png'], sheet_labels: {}, diagnostics: [] }
    end

    before do
      editor.on_show_page('area')
      editor.on_change('hunting_room_id', 1)
      editor.on_change('hunting_boundaries', '3')
      allow(editor).to receive(:map) { current }
      described_class.map_route = '/files/eohunter-maps/'
    end

    after { described_class.map_route = nil }

    it 'stays closed until asked for, then draws the sheet with a region per room and a mark per role' do
      expect(nodes(render, :composite)).to be_empty
      editor.on_toggle_map
      surface = nodes(render, :composite).first
      layers = surface.props[:layers]
      expect(layers.first).to include('kind' => 'image', 'src' => '/files/eohunter-maps/town.png')
      expect(layers.count { |layer| layer['kind'] == 'region' }).to eq(3)
      marks = layers.select { |layer| layer['kind'] == 'marker' }
      expect(marks.map { |mark| mark['shape'] }).to match_array(%w[ring cross])
      # The hunt's own room is an outline, never a fill over its number.
      outlines = layers.select { |layer| layer['kind'] == 'rectangle' }
      expect(outlines.map { |layer| layer['mode'] }).to eq(%w[stroke])
      # The whole sheet: the first room is where the sheet has it.
      region = layers.find { |layer| layer['key'] == 'room-1' }
      expect(region['x1']).to eq(100)
      expect(editor.map_origin).to eq(x: 0, y: 0)
    end

    it 'sizes the surface from the sheet file when it is on disk' do
      Dir.mktmpdir do |dir|
        bytes = ->(*values) { values.pack('C*') }
        png = bytes[0x89] + "PNG\r\n".b + bytes[0x1A, 0x0A] + [13].pack('N') + 'IHDR'.b + [1500, 900].pack('N2') + bytes[8, 2, 0, 0, 0]
        File.binwrite(File.join(dir, 'town.png'), png)
        gif = 'GIF89a'.b + [640, 480].pack('v2')
        File.binwrite(File.join(dir, 'old.gif'), gif)
        jpeg = bytes[0xFF, 0xD8, 0xFF, 0xE0] + [16].pack('n') + bytes[*([0] * 14)] +
               bytes[0xFF, 0xC0] + [17].pack('n') + bytes[8] + [700, 1200].pack('n2') + bytes[*([0] * 10)]
        File.binwrite(File.join(dir, 'photo.jpg'), jpeg)
        described_class.map_dir = dir
        expect(described_class.sheet_size('town.png')).to eq([1500, 900])
        expect(described_class.sheet_size('old.gif')).to eq([640, 480])
        expect(described_class.sheet_size('photo.jpg')).to eq([1200, 700])
        expect(described_class.sheet_size('missing.png')).to be_nil
        editor.on_toggle_map
        expect(nodes(render, :composite).first.props.slice(:width, :height)).to eq(width: 1500, height: 900)
      ensure
        described_class.map_dir = nil
      end
    end

    it 'assigns the chosen role on a left-click and clears on a right-click' do
      editor.on_toggle_map
      surface = nodes(render, :composite).first
      surface.on[:region_activate].call(FakeEvent.new({ region: 'room-2' }))
      expect(editor.settings['hunting_room_id']).to eq(2)
      # A left-click on the room that holds the role takes it away.
      surface.on[:region_activate].call(FakeEvent.new({ region: 'room-2' }))
      expect(editor.settings).not_to have_key('hunting_room_id')
      surface.on[:region_activate].call(FakeEvent.new({ region: 'room-2' }))
      # A client that reports the same left-click as a surface click too
      # must not undo it: that second report is ignored.
      surface.on[:surface_activate].call(FakeEvent.new({ region: 'room-2', button: 'primary', x: 5, y: 5 }))
      expect(editor.settings['hunting_room_id']).to eq(2)
      editor.on_assign_role('field_rest_room_id')
      surface.on[:region_activate].call(FakeEvent.new({ region: 'room-3' }))
      expect(editor.settings['field_rest_room_id']).to eq(3)
      # Room 3 is a boundary as well as the field rest. A right-click clears
      # one role at a time, the boundary first, so two clear both.
      surface.on[:surface_activate].call(FakeEvent.new({ region: 'room-3', button: 'secondary', x: 0, y: 0 }))
      expect(editor.list_entries('hunting_boundaries')).to be_empty
      expect(editor.settings['field_rest_room_id']).to eq(3)
      surface.on[:surface_activate].call(FakeEvent.new({ region: 'room-3', button: 'secondary', x: 0, y: 0 }))
      expect(editor.settings).not_to have_key('field_rest_room_id')
    end

    it 'finds a room from a point on the cropped surface' do
      editor.on_toggle_map
      render
      origin = editor.map_origin
      expect(editor.room_at(x: 150 - origin[:x], y: 110 - origin[:y])).to eq(2)
      expect(editor.room_at(x: 0, y: 0)).to be_nil
    end

    it 'shows the whole sheet, never a crop, at the height asked for' do
      editor.on_toggle_map
      surface = nodes(render, :composite).first
      # From the sheet's origin: nothing is cut off its top or left.
      expect(editor.map_origin).to eq(x: 0, y: 0)
      region = surface.props[:layers].find { |layer| layer['key'] == 'room-1' }
      expect(region['x1']).to eq(100)
      expect(surface.props[:width]).to be >= 200
      # Fitted to the width the window gives the view, and refitted when
      # the viewer reports another size.
      fitted = (editor.map_fit_width.to_f / surface.props[:width])
      expect(surface.props[:scale]).to be_within(0.001).of((fitted * 1000).floor / 1000.0)
      editor.window_size = { width: 2000, height: 1200 }
      wider = nodes(render, :composite).first.props[:scale]
      expect(wider).to be > surface.props[:scale]
      expect(nodes(render, :scroll).find { |node| node.props[:key] == 'view' }.props[:max_height]).to eq(1200 - EO::HunterSetup::Editor::MAP_CHROME_HEIGHT)
      expect(nodes(render, :select).map { |node| node.props[:key] }).not_to include('view', 'crop')
    end

    it 'offers every installed sheet when the hunt has no rooms yet, so marking can start' do
      editor.on_change('hunting_room_id', '')
      editor.on_change('hunting_boundaries', '')
      allow(editor).to receive(:map) { current.merge(rooms: [], markers: {}, hunting_room_ids: [], sheets: %w[town.png far.png]) }
      editor.on_toggle_map
      sheet = nodes(render, :select).find { |node| node.props[:key].to_s.start_with?('sheet-') }
      expect(sheet.props[:options].map { |option| option[:label] }).to eq(['Pick a sheet', 'far.png', 'town.png'])
      expect(sheet.props[:value]).to eq('')
    end

    it 'finds a creature behind a button and opens the map where it lives' do
      catalogue = [{ name: 'wolf', level: 8, family: 'canine', type: 'quadruped', otherclass: [], areas: ['Meadow'], traits: {} },
                   { name: 'coyote', level: 9, family: 'canine', type: 'quadruped', otherclass: [], areas: %w[Meadow Plains], traits: {} }]
      sheets = { 'wolf'   => [{ id: 'far.png', name: 'Far' }],
                 'coyote' => [{ id: 'far.png', name: 'Far' }, { id: 'town.png', name: 'Town' }] }
      app = editor.instance_variable_get(:@app)
      allow(app).to receive(:call).and_wrap_original do |original, request|
        case request['action']
        when 'creatures' then catalogue
        when 'creature_sheets' then sheets.fetch(request['name'])
        else original.call(request)
        end
      end
      editor.on_hunt_filter(:low, 1)
      editor.on_hunt_filter(:high, 100)
      # Closed: a button, no search, no map.
      builder = render
      expect(nodes(builder, :table)).to be_empty
      nodes(builder, :button).find { |node| node.props[:key] == 'show-finder' }.on[:activate].call(FakeEvent.new({}))
      builder = render
      section = nodes(builder, :group).find { |node| node.props[:key] == 'finder-section' }
      expect(section.props[:label]).to eq('Find a creature')
      list = nodes(builder, :table).find { |node| node.props[:key] == 'list' }
      expect(list.props[:rows].map { |row| row[:cells]['name'] }).to eq(%w[wolf coyote])
      # One sheet: the map opens on it, with the creature in the Find box.
      list.on[:row_activate].call(FakeEvent.new({ row: list.props[:rows].first[:key] }))
      expect(editor.map_open?).to be(true)
      expect(editor.sheet).to eq('far.png')
      expect(editor.room_query).to eq('wolf')
      expect(editor.sheet_choices).to be_empty
      # The draft is left alone: the rooms set before are as they were.
      expect(editor.settings).to include('hunting_room_id' => 1, 'hunting_boundaries' => '3')
      expect(editor.settings).not_to include('targets')
      # Several sheets: they are offered beside the Find box; picking one shows it.
      editor.on_sheet('town.png')
      list.on[:row_activate].call(FakeEvent.new({ row: list.props[:rows].last[:key] }))
      expect(editor.sheet).to eq('town.png')
      builder = render
      offered = nodes(builder, :select).find { |node| node.props[:key] == 'found-sheets' }
      expect(offered.props[:label]).to eq('2 sheets')
      expect(offered.props[:options].map { |option| option[:label] }).to eq(['pick one', 'Far', 'Town'])
      offered.on[:change].call(FakeEvent.new({ value: 'far.png' }))
      expect(editor.sheet).to eq('far.png')
      expect(nodes(render, :select).find { |node| node.props[:key] == 'found-sheets' }).to be_nil
      nodes(render, :button).find { |node| node.props[:key] == 'hide-finder' }.on[:activate].call(FakeEvent.new({}))
      expect(nodes(render, :table)).to be_empty
    end

    it 'finds a place or a room from the finder and shows its sheet with the room in view' do
      allow(editor).to receive(:area_names).and_return([{ name: 'Town', image: 'town.png' }, { name: 'Far Village', image: 'far.png' }])
      finds = [{ id: 3, title: 'Mead Hall', image: 'far.png', sheet_label: 'Far' },
               { id: 1, title: 'Mead Hall Gate', image: 'town.png', sheet_label: 'Town' }]
      app = editor.instance_variable_get(:@app)
      allow(app).to receive(:call).and_wrap_original do |original, request|
        request['action'] == 'room_search' ? finds.select { |room| room[:title].downcase.include?(request['query'].downcase) } : original.call(request)
      end
      stub_const('EO::HunterSetup::Session::FIND_DELAY', 0.02)
      settle = -> { sleep 0.08 }
      editor.on_toggle_map
      find = nodes(render, :select).find { |node| node.props[:key] == 'find' }
      expect(find.props[:editable]).to be(true)
      expect(find.props[:options].map { |option| option[:label] }).to include('Town', 'Far Village')
      # A place picked from the list goes straight to its sheet, at once.
      find.on[:change].call(FakeEvent.new({ value: 'Far Village' }))
      expect(editor.sheet).to eq('far.png')
      # Typing arrives a letter at a time: nothing is searched until it
      # pauses, the finder keeps the letters, and only the last is searched.
      %w[m me mea].each { |typed| find.on[:change].call(FakeEvent.new({ value: typed })) }
      expect(editor.room_matches).to be_empty
      expect(nodes(render, :select).find { |node| node.props[:key] == 'find' }.props[:value]).to eq('mea')
      find.on[:change].call(FakeEvent.new({ value: 'mead' }))
      settle.call
      expect(editor.room_query).to eq('mead')
      # Finds on several sheets are offered; picking one shows it, scrolled to.
      expect(editor.room_matches.size).to eq(2)
      found = nodes(render, :select).find { |node| node.props[:key] == 'found' }
      expect(found.props[:options].map { |option| option[:label] }).to include('Mead Hall Gate (1) - Town')
      found.on[:change].call(FakeEvent.new({ value: '1' }))
      expect(editor.sheet).to eq('town.png')
      expect(editor.room_matches).to be_empty
      expect(nodes(render, :composite).first.props[:scroll_to]).to eq('room-1')
      # A single find is shown without asking.
      editor.on_sheet('far.png')
      find.on[:change].call(FakeEvent.new({ value: 'gate' }))
      settle.call
      expect(editor.sheet).to eq('town.png')
      find.on[:change].call(FakeEvent.new({ value: 'zzz' }))
      settle.call
      expect(editor.status_error).to be(true)
    end

    it 'keeps showing the sheet being edited when the walk spills onto a bigger one' do
      editor.on_toggle_map
      expect(nodes(render, :select).find { |node| node.props[:key].to_s.start_with?('sheet-') }.props[:value]).to eq('town.png')
      spilled = rooms + (1..5).map { |n| { id: 100 + n, title: "Far #{n}", image: 'far.png', image_coords: [n * 20, 0, (n * 20) + 10, 10] } }
      allow(editor).to receive(:map) { current.merge(rooms: spilled) }
      expect(nodes(render, :select).find { |node| node.props[:key].to_s.start_with?('sheet-') }.props[:value]).to eq('town.png')
      expect(nodes(render, :composite).first.props[:layers].count { |layer| layer['kind'] == 'region' }).to eq(3)
      editor.on_sheet('far.png')
      expect(nodes(render, :composite).first.props[:layers].count { |layer| layer['kind'] == 'region' }).to eq(5)
      editor.on_new
      expect(editor.sheet).to be_nil
    end

    it 'keeps the crop and the scroll position through a click' do
      editor.on_toggle_map
      surface = nodes(render, :composite).first
      before = surface.props.slice(:width, :height)
      expect(surface.props[:scroll_to]).to eq('room-1')
      # Marking a far room must not recrop the view it was marked on.
      editor.on_assign_role('hunting_boundaries')
      surface.on[:region_activate].call(FakeEvent.new({ region: 'room-2' }))
      after_click = nodes(render, :composite).first
      expect(after_click.props.slice(:width, :height)).to eq(before)
      expect(after_click.props).not_to have_key(:scroll_to)
    end

    it 'zooms within bounds and resets' do
      editor.on_toggle_map
      4.times { editor.on_map_zoom('in') }
      expect(editor.map_scale).to be <= EO::HunterSetup::Editor::MAP_SCALE_RANGE.end
      editor.on_map_reset_zoom
      expect(editor.map_scale).to eq(1.0)
      button = nodes(render, :button).find { |node| node.props[:key] == 'zoom-reset' }
      expect(button.props[:label]).to eq('100%')
    end
  end

  it 'makes a stable, contract-safe key from a name and finds the name again' do
    key = described_class.row_key('a', "Darkstone Castle's Keep")
    expect(key).to match(/\A[A-Za-z0-9_.:-]{1,128}\z/)
    expect(described_class.row_name('a', key, ['Darkstone Castle', "Darkstone Castle's Keep"])).to eq("Darkstone Castle's Keep")
  end

  it 'tests a condition where the hunt would, and says what it said' do
    expect(described_class.test_condition('1 + 1 == 2', ->(code) { eval(code) })).to start_with('true right now')
    expect(described_class.test_condition('raise "no"', ->(code) { eval(code) })).to start_with('Raised RuntimeError')
    expect(described_class.test_condition('def', ->(code) { eval(code) })).to start_with('Not valid Ruby')
    expect(described_class.test_condition('', ->(code) { eval(code) })).to eq('Nothing to test.')
  end
end
