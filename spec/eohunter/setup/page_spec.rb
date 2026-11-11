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
     text_input textarea number_input select table composite image overlay].each do |type|
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
      char_settings: {}, templates: [], rooms: [], uid_resolver: ->(_uid) { [] },
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

  # A section's heading text, by the section's key; nil when it is not drawn.
  def heading(builder, key)
    row = nodes(builder, :columns).find { |node| node.props[:key] == "#{key}-heading" }
    row && row.children.find { |node| node.type == :text }.props[:content]
  end

  it 'draws the full editor with a tab for every page and a control for every setting' do
    # The boon settings show only when relevant; a value makes them so.
    editor.on_change('boons_flee', 'regen')
    described_class::GROUPS.values.flatten(1).each { |(heading, _keys, fold)| editor.on_toggle_fold(heading) if fold == :fold }
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
      next if described_class::HIDDEN.include?(field['key'])

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

  it 'keeps a folded group behind a button that says how much of it is set' do
    editor.on_show_page('rest')
    editor.on_change('field_rest_room_id', '228')
    button = nodes(render, :button).find { |node| node.props[:key] == 'fold' }
    expect(button.props[:label]).to eq('Show (1 set)')
    expect(render.all.map { |node| node.props[:key].to_s }).not_to include('field_rest_for')
    button.on[:activate].call(FakeEvent.new({}))
    expect(render.all.map { |node| node.props[:key].to_s }).to include('field_rest_for')
    expect(nodes(render, :button).find { |node| node.props[:key] == 'fold' }.props[:label]).to eq('Hide')
  end

  describe 'tooltips' do
    let(:fields) { editor.fields.to_h { |field| [field['key'], field] } }

    it 'say what a setting does and its default, and nothing about the engine' do
      tip = EO::HunterSetup::Form.tooltip(editor, fields['fried'])
      expect(tip).to eq('Go rest when your mind is at least this full. Above 100: never. Default: 100.')
      editor.fields.each do |field|
        # Only a worked example, at the end, may run over several lines.
        text = EO::HunterSetup::Form.tooltip(editor, field).split("\n\nFor example:\n").first
        expect(text).not_to match(/native|Engine default|Set in this hunt|
/), "#{field['key']}: #{text}"
        expect(text).not_to end_with(field['key']) unless field['key'] == text
      end
    end
  end

  it 'shows the loadout examples in their tooltips, line by line, and the engine accepts them' do
    field = editor.fields.find { |entry| entry['key'] == 'hunting_loadout_rules' }
    indent = EO::HunterSetup::Schema::NBSP * 2
    expect(EO::HunterSetup::Form.tooltip(editor, field)).to end_with(
      ["For example:", '- target: triton protector', "#{indent}set: slasher", '- type: undead', "#{indent}set: blunt",
       '- target: wight', "#{indent}type: undead", "#{indent}set: blessed"].join("\n")
    )
    rules = YAML.safe_load(EO::HunterSetup::Schema::LOADOUT_RULES_EXAMPLE.join("\n"))
    sets = YAML.safe_load(EO::HunterSetup::Schema::LOADOUT_SETS_EXAMPLE.join("\n"))
    profile = EO::Engine::Profile.new({ 'hunting_right_hand' => 'ready:weapon', 'hunting_loadout_rules' => rules,
                                        'hunting_loadout_sets' => sets })
    expect(profile.loadout_selection).to be_managed
  end

  it 'offers turbo as a choice, showing a saved true as All' do
    skip 'this engine has no turbo' unless editor.fields.any? { |field| field['key'] == 'turbo' }

    editor.on_show_page('hunting')
    editor.on_change('turbo', 'true')
    turbo = nodes(render, :select).find { |node| node.props[:key] == 'turbo' }
    expect(turbo.props[:options].map { |option| option[:value] }).to include('off', 'stance', 'all')
    expect(turbo.props[:value]).to eq('all')
  end

  describe 'the Cleanse settings' do
    let(:ecleanse) { File.join(@directory, 'GSIV', 'Example', 'ecleanse.yaml') }

    before { editor.on_show_page('recovery') }

    it 'draws a control for every preference and no YAML box' do
      keys = render.all.map { |node| node.props[:key].to_s }
      # stand_stance is the hunt's own, on the Hunting page.
      expect(keys).to include(*(EO::Engine::Cleanse::KEYS - [:stand_stance]).map(&:to_s))
      expect(render.all.map(&:type)).not_to include(:textarea)
    end

    it 'keeps what is ticked in the hunt, and off is absent' do
      session.call(:recovery_set, double(payload: { value: true }), 'cleanse_poison')
      expect(editor.settings['recovery']).to eq('cleanse_poison' => true)
      expect(EO::Engine::Profile.new({ 'recovery' => editor.settings['recovery'] }).recovery_policy.cleanse_poison).to be(true)
      session.call(:recovery_set, double(payload: { value: false }), 'cleanse_poison')
      expect(editor.settings).not_to have_key('recovery')
    end

    it 'allows one stunman choice, as ecleanse does' do
      editor.on_recovery_set('use_berserk_stunned', true)
      editor.on_recovery_set('use_stance1', true)
      serial = editor.draft_serial
      editor.on_recovery_set('use_hide', true)
      expect(editor.settings['recovery']).to eq('use_berserk_stunned' => true, 'use_hide' => true)
      expect(editor.draft_serial).to eq(serial + 1)
    end

    it 'offers the import only when ecleanse has something, and it replaces the draft unsaved' do
      expect(render.all.map { |node| node.props[:key].to_s }).not_to include('import-ecleanse')
      FileUtils.mkdir_p(File.dirname(ecleanse))
      File.write(ecleanse, ":cleanse_poison: true\n:use_619: false\n:safe_room: '228'\n:stop_scripts: bigshot\n:troubadours_rally: true\n:stand_stance: offensive\n")
      before = File.read(ecleanse)
      expect(render.all.map { |node| node.props[:key].to_s }).to include('import-ecleanse')
      editor.on_recovery_set('use_hide', true)
      serial = editor.draft_serial
      session.call(:import_ecleanse, double(payload: {}))
      expect(editor.settings['recovery']).to eq('cleanse_poison' => true, 'safe_room' => '228')
      expect(editor.draft_serial).to eq(serial + 1)
      expect(editor).to be_dirty
      expect(File.read(ecleanse)).to eq(before)
    end

    it 'falls back to the toggles ecleanse keeps in CharSettings without a file' do
      expect(EO::HunterSetup::Runtime.ecleanse_settings(ecleanse, char_settings: { 'avoid_webs' => true, 'other' => true })).to eq('avoid_webs' => true)
    end
  end

  describe 'replacing the whole draft' do
    def serial_after
      before = editor.draft_serial
      yield
      editor.draft_serial - before
    end

    it 'gives the page new boxes when a hunt is opened, started or reverted' do
      editor.on_change('flee_count', '3')
      editor.on_rename('forest')
      editor.on_save
      expect(serial_after { editor.on_load('forest') }).to eq(1)
      editor.on_change('flee_count', '4')
      expect(serial_after { editor.on_revert }).to eq(1)
      expect(serial_after { editor.on_new }).to eq(1)
    end

    it 'keeps the boxes, and what is typed in them, through an ordinary edit or a failed open' do
      expect(serial_after { editor.on_change('flee_count', '3') }).to eq(0)
      expect(serial_after { editor.on_load('no_such_hunt') }).to eq(0)
    end

    it 'puts the count in the key of the box everything is drawn in' do
      recorder = instance_double('ui')
      allow(recorder).to receive(:stack) { |**props| expect(props[:key]).to eq("root-#{editor.draft_serial}") }
      described_class.render(recorder, editor, session)
      expect(recorder).to have_received(:stack)
    end
  end

  describe 'the creature search' do
    before do
      editor.on_show_page('creatures')
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
        data_dir: @directory, game: 'GSIV', character: 'Example', char_settings: {}, level: 20,
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
    editor.on_show_page('equipment')
    expect(nodes(render, :text_input).find { |node| node.props[:key] == 'hunting_scripts' }).not_to be_nil
  end

  it 'shows validation messages beside the setting they are about' do
    editor.on_show_page('hunting')
    editor.on_change('hunting_stance', 'sideways')
    editor.on_validate
    expect(editor.warnings.map { |entry| entry['key'] || entry[:key] }).to include('hunting_stance')
    builder = render
    row = nodes(builder, :stack).find { |node| node.props[:key] == 'line-hunting_stance' }
    expect(row.children.map(&:type)).to include(:text)
    expect(row.children.last.props[:tone]).to eq(:danger)
  end

  it 'draws search results as the pages do, under the page each setting is on' do
    search = nodes(render, :text_input).find { |node| node.props[:key] == 'search' }
    expect(search.props[:change_mode]).to eq(:input)
    search.on[:change].call(FakeEvent.new({ value: 'stance' }))
    builder = render
    expect(nodes(builder, :tabs)).to be_empty
    expect(nodes(builder, :text).find { |node| node.props[:key] == 'found' }.props[:content]).to match(/\A\d+ matching settings\z/)
    grid = nodes(builder, :grid).find { |node| node.props[:key] == 'page' }
    headings = grid.children.select { |node| node.props[:key].to_s.match?(/\Ap-[a-z]+\z/) }.map { |node| node.props[:content] }
    expect(headings.first).to eq('Hunting behavior')
    # The stances keep their line, as on Hunting behavior.
    expect(nodes(builder, :select).map { |node| node.props[:key] }).to include('hunting_stance', 'wander_stance', 'stand_stance')
    # Cleanse comes up as its ticks, not a stack of its own.
    search.on[:change].call(FakeEvent.new({ value: 'cleanse' }))
    expect(nodes(render, :grid).map { |node| node.props[:key] }).to include('cleanse')
    search.on[:change].call(FakeEvent.new({ value: 'no such setting anywhere' }))
    expect(nodes(render, :text).find { |node| node.props[:key] == 'found' }.props[:content]).to eq('No setting matches')
  end

  it 'orders Recovery as the group, Cleanse by what each tick is for, then Death' do
    editor.on_show_page('recovery')
    builder = render
    grid = nodes(builder, :grid).find { |node| node.props[:key] == 'page' }
    headings = grid.children.select { |node| node.props[:emphasis] == :strong && node.props[:placement] == { column: 1 } }
    expect(headings.map { |node| node.props[:content] }).to eq(['In the group', 'Cleanse', 'Death'])
    cleanse = nodes(builder, :grid).find { |node| node.props[:key] == 'cleanse' }
    order = cleanse.children.map { |node| node.props[:content] || node.props[:label] || node.props[:key] }
    expect(order.select { |text| %w[Afflictions Hazards Disarmed].include?(text) || text == 'When stunned' })
      .to eq(['Afflictions', 'Hazards', 'Disarmed', 'When stunned'])
    # The safe room sits under the itchy curse it is for.
    expect(order[order.index('Manage itchy curse') + 1]).to eq('safe-room')
    # The weapon spells are with the weapon, not with the stun.
    expect(order.index('Mass Calm (619)')).to be_between(order.index('Disarmed'), order.index('When stunned'))
    expect(order.index('Stance 1')).to be > order.index('When stunned')
    # The one-time import comes after the lists, not above them.
    allow(editor).to receive(:ecleanse_to_import?).and_return(true)
    page = nodes(render, :grid).find { |node| node.props[:key] == 'page' }.children.map { |node| node.props[:key] }
    expect(page.index('import')).to be > page.index('cleanse')
    expect(page.index('import')).to be < page.index('g2') # Death
    labels = nodes(builder, :checkbox).map { |node| node.props[:label] }
    expect(labels).to include('Rally the group (1040)', 'Shout 1040')
    expect(labels).not_to include("Troubadour's Rally")
  end

  it 'greys out the Cleanse choices this character cannot use, and leaves them out of an import' do
    allow(editor).to receive(:recovery_unusable) { |key| key == 'use_919' ? "You do not know Wizard's Shield (919)." : nil }
    editor.on_show_page('recovery')
    tick = -> { nodes(render, :checkbox).find { |node| node.props[:key] == 'use_919' } }
    expect(tick.call.props[:disabled]).to be(true)
    expect(tick.call.props[:tooltip]).to eq("You do not know Wizard's Shield (919).")
    expect(nodes(render, :checkbox).find { |node| node.props[:key] == 'use_619' }.props[:disabled]).to be(false)
    # Already ticked, it stays clickable so it can be unticked.
    editor.settings['recovery'] = { 'use_919' => true }
    expect(tick.call.props[:disabled]).to be(false)
    expect(tick.call.props[:tooltip]).to include('untick it')
    allow(editor).to receive(:ecleanse_settings).and_return('use_919' => true, 'cleanse_poison' => true)
    editor.on_import_ecleanse
    expect(editor.settings['recovery']).to eq('cleanse_poison' => true)
    expect(editor.status).to include('Left out 1 this character cannot use.')
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

  it 'lists the creatures in the hunt\'s rooms, each with a tick that hunts it or leaves it alone' do
    editor.on_show_page('creatures')
    editor.on_change('hunting_room_id', 1)
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
    builder = render
    expect(heading(builder, 'here')).to eq('Creatures in the hunt\'s rooms')
    # No frames: a group sits tight on its contents in compact density.
    expect(nodes(builder, :group)).to be_empty
    # The start is chosen, so there is no next step to offer.
    expect(nodes(builder, :button).map { |node| node.props[:key] }).not_to include('next')
    ticks = nodes(builder, :checkbox).select { |node| node.props[:key].start_with?('hunt-') }
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
    ticks = -> { nodes(render, :checkbox).select { |node| node.props[:key].start_with?('hunt-') } }
    expect(ticks.call.map { |node| node.props[:checked] }).to eq([true, true, false])
    # Hunt all ticks every box and lists every one. Each box that changed is
    # a new box: the browser keeps a tick it was given, and an untouched
    # box drawn unticked stayed unticked when only its value changed.
    before = ticks.call.map { |node| node.props[:key] }
    nodes(render, :button).find { |node| node.props[:key] == 'hunt-all' }.on[:activate].call(FakeEvent.new({}))
    expect(ticks.call.map { |node| node.props[:checked] }).to eq([true, true, true])
    expect(ticks.call.map { |node| node.props[:key] }).to eq(%w[hunt-on hunt-on hunt-on])
    expect(before.last).to eq('hunt-unset')
    expect(editor.list_entries('targets').map { |entry| entry.split('(').first }).to eq(%w[kobold rolton ghoul])
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
    expect(heading(render, 'pick-boons_flee')).to be_nil
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

  it 'lists saved hunts one a line, the open one in bold: Default ticks it, Delete asks in a dialog' do
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
    within = lambda do |builder, name, type, key|
      nodes(builder, type).find { |node| node.props[:key].to_s.start_with?(key) && node.cid.include?(line[builder, name].cid) }
    end
    builder = render
    expect(nodes(builder, :table).map { |node| node.cid }).not_to include(a_string_including('saved'))
    expect(nodes(builder, :group).map { |node| node.props[:key] }).not_to include('confirm-delete')
    expect(nodes(builder, :select).map { |node| node.props[:key] }).not_to include('active')
    expect(%w[forest plains].map { |name| within[builder, name, :text, 'name'].props[:content] }).to eq(%w[forest plains])
    editor.on_load('forest')
    builder = render
    expect(within[builder, 'forest', :text, 'name'].props[:emphasis]).to eq(:strong)
    expect(within[builder, 'plains', :text, 'name'].props[:emphasis]).to eq(:normal)
    expect(nodes(builder, :table).map { |node| node.props[:key] }).not_to include('list')
    expect(editor.name).to eq('forest')
    expect(editor.revision).to be_a(String)
    # One default at a time: ticking another makes the first a new, unticked
    # box, so the browser's old tick is not left showing beside the new one.
    within[render, 'plains', :checkbox, 'default'].on[:change].call(FakeEvent.new({ value: true }))
    builder = render
    was = within[builder, 'forest', :checkbox, 'default'].props[:key]
    within[builder, 'forest', :checkbox, 'default'].on[:change].call(FakeEvent.new({ value: true }))
    builder = render
    expect(editor.active_profile).to eq('forest')
    expect(within[builder, 'plains', :checkbox, 'default'].props).to include(key: 'default-off', checked: false)
    expect(within[builder, 'forest', :checkbox, 'default'].props[:key]).not_to eq(was)
    expect(%w[forest plains].count { |name| within[builder, name, :checkbox, 'default'].props[:checked] }).to eq(1)
    editor.on_set_active(nil)
    # Delete on the other line asks about that one, in a dialog. No keeps
    # it; yes deletes it.
    asked = []
    answer = false
    session = EO::HunterSetup::Session.new(editor: editor, refresh: -> {},
                                           ask: ->(**question, &reply) { asked << question; reply.call(answer) })
    builder = RecordingBuilder.new
    described_class.render(builder, editor, session)
    expect(nodes(builder, :button).map { |node| node.props[:key] }).not_to include('confirm')
    delete = -> { within[builder, 'plains', :button, 'delete'].on[:activate].call(FakeEvent.new({})) }
    delete.call
    expect(asked.last).to include(title: 'Delete hunt', yes: 'Delete')
    expect(asked.last[:body]).to start_with('Delete plains?')
    expect(editor.profiles).to eq(%w[forest plains])
    expect(editor.pending_delete).to be_nil
    answer = true
    delete.call
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
      # A setting this engine lacks may be named; the schema still has to
      # place it on this page, for the engine that has it.
      groups.each do |(heading, members)|
        allowed = (EO::HunterSetup::Schema::PAGES[page] || []) + keys
        named = members.flatten.reject { |key| key.match?(/\Ahunting_commands/) }
        expect(allowed).to include(*named), "#{page}: #{heading} names a setting the page does not have"
      end
      grouped = described_class.grouped(fields).flat_map { |(_heading, members)| members.flatten.map { |field| field['key'] } }
      expect(grouped).to match_array(keys - described_class::HIDDEN)
    end
  end

  it 'keeps every cell of every page inside its grid, as Lich requires' do
    described_class::GROUPS.values.flatten(1).each { |(heading, _keys, fold)| editor.on_toggle_fold(heading) if fold == :fold }
    described_class::PAGES.each do |item|
      editor.on_show_page(item[:id])
      nodes(render, :grid).each do |grid|
        grid.children.each do |child|
          at = child.props[:placement] || {}
          next unless at[:column]

          expect(at[:column] + (at[:span] || 1) - 1).to be <= grid.props[:cols], "#{item[:id]}: #{child.props[:key]} at #{at}"
        end
      end
    end
  end

  it 'puts the settings of a line in the same label and box columns as every other line' do
    editor.on_show_page('hunting')
    grid = nodes(render, :grid).find { |node| node.props[:key] == 'page' }
    expect(grid.props[:cols]).to eq(6)
    at = grid.children.to_h { |child| [child.props[:key], child.props[:placement]] }
    expect(at['l-hunting_stance']).to eq(column: 1)
    expect(at['hunting_stance']).to eq(column: 2)
    expect(at['l-wander_stance']).to eq(column: 3)
    expect(at['wander_stance']).to eq(column: 4)
    expect(at['l-stand_stance']).to eq(column: 5)
    expect(at['stand_stance']).to eq(column: 6)
    expect(at['flee_count']).to eq(column: 2)
    expect(at['lone_targets_only']).to eq(column: 4, span: 2)
    expect(at['f-flee_message']).to eq(column: 2, span: 5)
    stance = grid.children.find { |child| child.props[:key] == 'hunting_stance' }
    expect(stance.props).not_to have_key(:label)
    expect(grid.children.find { |child| child.props[:key] == 'l-hunting_stance' }.props[:content]).to eq('Attack')
    expect(grid.children.find { |child| child.props[:key] == 'lone_targets_only' }.props[:label]).to eq('Lone targets')
    expect(at.keys).not_to include('l-box_in_hand', 'f-box_in_hand', 'box_in_hand')
  end

  describe 'the Combat page' do
    before { editor.on_show_page('combat') }

    it 'lists every routine by its letter with Quick and Fried last, in the page grid' do
      editor.on_change('hunting_commands_b', 'kick, punch')
      grid = nodes(render, :grid).find { |node| node.props[:key] == 'page' }
      words = grid.children.select { |node| node.props[:key].to_s.start_with?('l-hunting_commands', 'l-quick', 'l-disable') }
      expect(words.map { |node| node.props[:content] }).to eq(%w[a b c d e f g h i j Quick Fried])
      box = nodes(render, :text_input).find { |node| node.props[:key].to_s.start_with?('hunting_commands_b') }
      expect(box.props[:value]).to eq('kick, punch')
      expect(box.props[:label]).to be_nil
      box.on[:change].call(FakeEvent.new({ value: 'kick' }))
      expect(editor.list_entries('hunting_commands_b')).to eq(['kick'])
    end

    it 'folds aiming and unarmed away, counting only what is really set' do
      editor.on_change('uac_smite', false)
      editor.on_change('mstrike_mob', '3')
      labels = nodes(render, :button).select { |node| node.props[:key] == 'fold' }.map { |node| node.props[:label] }
      expect(labels).to eq(['Show', 'Show (1 set)'])
      expect(nodes(render, :text_input).map { |node| node.props[:key].to_s }).not_to include(a_string_starting_with('ambush'))
      editor.on_toggle_fold('Aiming')
      words = nodes(render, :text).select { |node| %w[l-ambush l-archery_aim l-aim].include?(node.props[:key]) }
      expect(words.map { |node| node.props[:content] }).to eq(%w[Ambush Ranged Unarmed])
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

    it 'stays closed until asked for, then draws the sheet with a mark per role and no region per room' do
      expect(nodes(render, :composite)).to be_empty
      editor.on_toggle_map
      surface = nodes(render, :composite).first
      layers = surface.props[:layers]
      expect(layers.first).to include('kind' => 'image', 'src' => '/files/eohunter-maps/town.png')
      # Rooms cost no layers: a click is a point, and the room under it is
      # found, as Lich's map does. The one region is where the view opens,
      # and it takes no clicks.
      regions = layers.select { |layer| layer['kind'] == 'region' }
      expect(regions.map { |layer| [layer['key'], layer['activates']] }).to eq([['room-1', false]])
      expect(surface.on.keys).to contain_exactly(:surface_activate, :zoom)
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
      # A click is a point on the sheet; the room under it is found.
      click = ->(x, button = 'primary') { surface.on[:surface_activate].call(FakeEvent.new({ button: button, x: x, y: 110 })) }
      click.call(150)
      expect(editor.settings['hunting_room_id']).to eq(2)
      # A left-click on the room that holds the role takes it away.
      click.call(150)
      expect(editor.settings).not_to have_key('hunting_room_id')
      click.call(150)
      expect(editor.settings['hunting_room_id']).to eq(2)
      # Between rooms is nothing.
      click.call(130)
      expect(editor.settings['hunting_room_id']).to eq(2)
      editor.on_assign_role('field_rest_room_id')
      click.call(190)
      expect(editor.settings['field_rest_room_id']).to eq(3)
      # Room 3 is a boundary as well as the field rest. A right-click clears
      # one role at a time, the boundary first, so two clear both.
      click.call(190, 'secondary')
      expect(editor.list_entries('hunting_boundaries')).to be_empty
      expect(editor.settings['field_rest_room_id']).to eq(3)
      click.call(190, 'secondary')
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

    it 'picks the creature on What to hunt: it is the target, its rooms are fenced, and Next goes to the map' do
      catalogue = [{ name: 'wolf', level: 8, family: 'canine', type: 'quadruped', otherclass: [], areas: ['Meadow'], traits: {} },
                   { name: 'coyote', level: 9, family: 'canine', type: 'quadruped', otherclass: [], areas: %w[Meadow Plains], traits: {} }]
      fences = { 'wolf'   => { room_ids: [1, 2], boundary_ids: [5, 6], pockets: 1, sheets: [{ id: 'far.png', name: 'Far' }] },
                 'coyote' => { room_ids: [7, 8, 9], boundary_ids: [10, 11, 12], pockets: 2,
                               sheets: [{ id: 'far.png', name: 'Far' }, { id: 'town.png', name: 'Town' }] } }
      asked = []
      app = editor.instance_variable_get(:@app)
      allow(app).to receive(:call).and_wrap_original do |original, request|
        case request['action']
        when 'creatures' then catalogue
        when 'creature_fence' then fences.fetch(request['name'])
        when 'creatures_here'
          asked << request['room_ids']
          [{ name: 'coyote', level: 9 }, { name: 'rat', level: 2 }]
        else original.call(request)
        end
      end
      editor.on_hunt_filter(:low, 1)
      editor.on_hunt_filter(:high, 100)
      # What to hunt comes before Where to hunt.
      ids = EO::HunterSetup::Editor::NAV_ITEMS.map { |item| item[:id] }
      expect(ids.index('creatures')).to eq(ids.index('area') - 1)
      editor.on_show_page('creatures')
      # No targets yet, so the search is open.
      builder = render
      expect(heading(builder, 'finder')).to eq('Find a creature')
      fold = nodes(builder, :button).find { |node| node.props[:key] == 'fold' && node.cid.include?('finder-heading') }
      expect(fold.props[:label]).to eq('Hide')
      list = nodes(builder, :table).find { |node| node.props[:key] == 'list' }
      expect(list.props[:rows].map { |row| row[:cells]['name'] }).to eq(%w[wolf coyote])
      # One sheet: fenced, the target, the map ready for the start room. The
      # start is inside the fence, so it stays and the hunt's rooms are listed.
      # The click's selection is the viewer's, kept by Lich only for a
      # bound event: unbound, the redraw after a pick cleared it.
      expect(list.on).to include(:selection_change)
      list.on[:row_activate].call(FakeEvent.new({ row: list.props[:rows].first[:key] }))
      expect(editor.settings['hunting_boundaries']).to eq('5, 6')
      expect(editor.list_entries('targets')).to eq(['wolf'])
      expect(editor.settings['hunting_room_id']).to eq(1)
      expect(editor.map_open?).to be(true)
      expect(editor.sheet).to eq('far.png')
      expect(editor.assign_role).to eq('hunting_room_id')
      expect(editor.status).to start_with('Hunting wolf: fenced where it lives.')
      expect(editor.creature_search_open?).to be(true)
      # Several sheets and a fence elsewhere: it replaces the targets and the
      # start, and the fence's own rooms are listed until a start is chosen.
      list.on[:row_activate].call(FakeEvent.new({ row: list.props[:rows].last[:key] }))
      expect(editor.settings['hunting_boundaries']).to eq('10, 11, 12')
      expect(editor.list_entries('targets')).to eq(['coyote'])
      expect(editor.settings['hunting_room_id'].to_s).to eq('')
      expect(editor.status).to include('its 2 areas', 'Targets were wolf.')
      builder = render
      expect(asked.last).to eq([7, 8, 9])
      expect(heading(builder, 'here')).to eq('Creatures in the fence')
      # Next moves the viewer: the selected tab is theirs, so it is set for
      # them on the tabs just drawn, as well as in the draft.
      set = []
      moving = EO::HunterSetup::Session.new(editor: editor, refresh: -> {}, set_view: ->(*change) { set << change })
      builder = RecordingBuilder.new
      described_class.render(builder, editor, moving)
      tabs = nodes(builder, :tabs).first
      nodes(builder, :button).find { |node| node.props[:key] == 'next' }.on[:activate].call(FakeEvent.new({}))
      expect(EO::HunterSetup::Editor::NAV_ITEMS[editor.page_index][:id]).to eq('area')
      expect(set).to eq([[tabs.cid, :selected, editor.page_index]])
      # On the map, the sheets are offered beside the Find box; picking one shows it.
      builder = render
      offered = nodes(builder, :select).find { |node| node.props[:key] == 'found-sheets' }
      expect(offered.props[:options].map { |option| option[:label] }).to eq(['pick one', 'Far', 'Town'])
      offered.on[:change].call(FakeEvent.new({ value: 'far.png' }))
      expect(editor.sheet).to eq('far.png')
    end

    it 'lists a fence of several areas apart, starts only where the creature lives, and outlines its rooms' do
      catalogue = [{ name: 'kelpie', level: 112, family: 'equine', type: 'quadruped', otherclass: [], areas: ['Grief'], traits: {} }]
      fence = { room_ids: [1, 2, 7], boundary_ids: [3], pockets: 2, areas: [[1, 2], [7]], sheets: [{ id: 'town.png', name: 'Town' }] }
      app = editor.instance_variable_get(:@app)
      allow(app).to receive(:call).and_wrap_original do |original, request|
        case request['action']
        when 'creatures' then catalogue
        when 'creature_fence' then fence
        when 'creatures_here'
          request['room_ids'] == [7] ? [{ name: 'kelpie', level: 112 }, { name: 'whelk', level: 107 }] : [{ name: 'kelpie', level: 112 }, { name: 'shark', level: 110 }]
        else original.call(request)
        end
      end
      allow(editor).to receive(:map) { current.merge(hunting_room_ids: editor.settings['hunting_room_id'].to_s.empty? ? [] : [1, 2]) }
      editor.on_change('hunting_room_id', '')
      editor.on_hunt_filter(:low, 1)
      editor.on_hunt_filter(:high, 200)
      editor.on_find_creature('kelpie')
      editor.on_show_page('creatures')
      builder = render
      headings = nodes(builder, :text).select { |node| node.props[:key].to_s.match?(/\Aarea-\d+-heading\z/) }.map { |node| node.props[:content] }
      expect(headings).to eq(['Area 1, 2 rooms', 'Area 2, 1 room'])
      # Each area's own Hunt all takes only that area's creatures.
      area_two = nodes(builder, :button).find { |node| node.props[:key] == 'hunt-all' && node.cid.include?('area-1') }
      area_two.on[:activate].call(FakeEvent.new({}))
      expect(editor.list_entries('targets')).to eq(%w[kelpie whelk])
      expect(editor.list_entries('targets')).not_to include('shark')
      # On the map, the creature's rooms are outlined, and a start outside them is refused.
      editor.on_show_page('area')
      editor.on_toggle_map unless editor.map_open?
      surface = nodes(render, :composite).first
      teal = Hash[EO::HunterSetup::Editor::ROLE_COLOURS.fetch('creature').map { |k, v| [k.to_s, v] }]
      expect(surface.props[:layers].count { |layer| layer['color'] == teal || layer['color'] == EO::HunterSetup::Editor::ROLE_COLOURS.fetch('creature') }).to be >= 1
      editor.on_assign_room('hunting_room_id', 3)
      expect(editor.settings['hunting_room_id'].to_s).to eq('')
      expect(editor.status).to eq('Room 3 is not where kelpie lives. Pick one of its rooms, outlined in teal.')
      editor.on_assign_room('hunting_room_id', 1)
      expect(editor.settings['hunting_room_id']).to eq(1)
      # With a start, the list is the hunt's rooms again, one list.
      editor.on_show_page('creatures')
      expect(nodes(render, :text).map { |node| node.props[:key] }).not_to include('area-0-heading')
      # The creature's own role is not something a click can set.
      roles = nodes(render, :select).find { |node| node.props[:key] == 'role' }
      expect(roles).to be_nil.or(satisfy { |node| node.props[:options].none? { |option| option[:value] == 'creature' } })
    end

    it "stacks composites when the marks overfill one, as Lich's map does, dropping none" do
      many = (1..600).map { |id| { id: id, title: "Room #{id}", image: 'town.png', image_coords: [id * 10, 0, (id * 10) + 8, 8] } }
      allow(editor).to receive(:map) { current.merge(rooms: many, hunting_room_ids: []) }
      allow(editor).to receive_messages(fence_rooms: many.map { |room| room[:id] }, fence_creature: 'giant rat')
      editor.on_toggle_map unless editor.map_open?
      builder = render
      stack = nodes(builder, :overlay).find { |node| node.props[:key] == 'surfaces' }
      surfaces = stack.children.select { |node| node.type == :composite }
      expect(surfaces.size).to be > 1
      expect(surfaces.map { |node| node.props[:layers].size }).to all(be <= described_class::MAP_LAYERS)
      teal = EO::HunterSetup::Editor::ROLE_COLOURS.fetch('creature')
      outlined = surfaces.sum { |node| node.props[:layers].count { |layer| layer['color'] == teal } }
      # Every creature room is outlined but those with a role of their own
      # (the start and the boundary), which show that role's mark instead.
      expect(outlined).to eq(600 - many.count { |room| editor.role_for(room[:id]) })
      expect(outlined).to eq(598)
      # Each takes the clicks, and one says where the view opens.
      expect(surfaces.map { |node| node.on.keys.sort }.uniq).to eq([%i[surface_activate zoom]])
      expect(surfaces.count { |node| node.props.key?(:scroll_to) }).to be <= 1
    end

    it 'opens What to hunt with the search folded on a hunt that already has targets' do
      editor.on_change('targets', 'wolf')
      editor.on_show_page('creatures')
      expect(editor.creature_search_open?).to be(false)
      builder = render
      expect(heading(builder, 'finder')).to eq('Find a creature')
      fold = nodes(builder, :button).find { |node| node.props[:key] == 'fold' && node.cid.include?('finder-heading') }
      expect(fold.props[:label]).to eq('Show')
      fold.on[:activate].call(FakeEvent.new({}))
      expect(editor.creature_search_open?).to be(true)
      expect(nodes(render, :stack).map { |node| node.props[:key] }).to include('finder-section')
    end

    it 'leaves the town rest off the map: it is almost never on the hunting map' do
      allow(editor).to receive(:map) { current }
      editor.on_toggle_map unless editor.map_open?
      role = nodes(render, :select).find { |node| node.props[:key] == 'role' }
      expect(role.props[:options].map { |option| option[:value] }).to eq(%w[hunting_boundaries hunting_room_id rallypoint_room_ids field_rest_room_id])
    end

    it 'sorts the creatures from the Sort by select, level as a number, and shows details from the Details cell' do
      catalogue = [{ name: 'wolf', level: 9, family: 'canine', type: 'quadruped', otherclass: [], areas: ['Meadow'], traits: {} },
                   { name: 'Bear', level: 10, family: 'ursine', type: 'quadruped', otherclass: [], areas: ['Wood'], traits: {} }]
      shown = []
      session = EO::HunterSetup::Session.new(editor: editor, refresh: -> {}, details: ->(found) { shown << found })
      app = editor.instance_variable_get(:@app)
      allow(app).to receive(:call).and_wrap_original do |original, request|
        case request['action']
        when 'creatures' then catalogue
        when 'creature_details' then { title: "#{request['name']}, level 9", lines: [[:line, 'canine quadruped']] }
        when 'creature_fence' then raise 'a Details click must not fence'
        else original.call(request)
        end
      end
      editor.on_hunt_filter(:low, 1)
      editor.on_hunt_filter(:high, 100)
      editor.on_show_page('creatures')
      builder = RecordingBuilder.new
      described_class.render(builder, editor, session)
      list = nodes(builder, :table).find { |node| node.props[:key] == 'list' }
      # Plain headings: a sortable one is a full-size button in Lich.
      expect(list.props[:sortable]).to be_nil
      expect(list.props[:columns].map { |column| column[:sortable] || column[:activatable] }).to all(be_nil)
      expect(list.props[:rows].map { |row| row[:cells]['name'] }).to eq(%w[wolf Bear])
      sort = nodes(builder, :select).find { |node| node.props[:key] == 'sort' }
      sort.on[:change].call(FakeEvent.new({ value: 'name' }))
      builder = RecordingBuilder.new
      described_class.render(builder, editor, session)
      list = nodes(builder, :table).find { |node| node.props[:key] == 'list' }
      expect(list.props[:rows].map { |row| row[:cells]['name'] }).to eq(%w[Bear wolf])
      wolf = list.props[:rows].find { |row| row[:cells]['name'] == 'wolf' }
      list.on[:row_activate].call(FakeEvent.new({ row: wolf[:key], column: 'details' }))
      expect(shown).to eq([{ title: 'wolf, level 9', lines: [[:line, 'canine quadruped']] }])
      expect(editor.settings['hunting_boundaries']).to eq('3')
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
      sheet_image = -> { nodes(render, :composite).first.props[:layers].find { |layer| layer['kind'] == 'image' }['src'] }
      expect(sheet_image.call).to end_with('town.png')
      editor.on_sheet('far.png')
      expect(sheet_image.call).to end_with('far.png')
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
      surface.on[:surface_activate].call(FakeEvent.new({ button: 'primary', x: 150, y: 110 }))
      expect(editor.list_entries('hunting_boundaries')).to include('2')
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
