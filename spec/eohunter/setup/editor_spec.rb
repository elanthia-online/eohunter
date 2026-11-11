# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require_relative '../../../scripts/eohunter/setup/runtime'

# Load the engine policy classes and setup modules before the describe
# block names Editor.
EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Editor do
  around do |example|
    Dir.mktmpdir('hunter-editor') do |directory|
      @directory = directory
      example.run
    end
  end

  let(:app) do
    EO::HunterSetup::Runtime.app(
      data_dir: @directory, game: 'GSIV', character: 'Example',
      templates: [], rooms: [], uid_resolver: ->(_uid) { [] }
    )
  end
  let(:editor) { described_class.new(app: app) }

  it 'exposes every schema field, and assigns each one to a rendered page' do
    expect(editor.fields).not_to be_empty
    placed = described_class::SETTINGS_PAGES.flat_map { |page| editor.fields_for(page) }
    # A field whose page has no tab would be unreachable in the editor.
    expect(placed.map { |field| field['key'] }).to match_array(editor.fields.map { |field| field['key'] })
  end

  it 'starts clean and reports unsaved edits' do
    expect(editor).not_to be_dirty
    editor.on_change('hunting_stance', 'offensive')
    expect(editor).to be_dirty
    expect(editor.settings).to include('hunting_stance' => 'offensive')
  end

  it 'removes a setting when it is cleared, so the hunt falls back to its default' do
    editor.on_change('hunting_stance', 'offensive')
    editor.on_change('hunting_stance', '')
    expect(editor.settings).not_to have_key('hunting_stance')
  end

  it 'saves a loaded hunt under a new name as a new hunt, leaving the original alone' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    editor.on_save
    editor.on_rename('plains')
    editor.on_change('hunting_stance', 'defensive')
    expect(editor.on_save).to be(true)
    expect(editor.status_error).to be(false)
    expect(editor.profiles).to contain_exactly('forest', 'plains')
    editor.on_load('forest')
    expect(editor.settings['hunting_stance']).to eq('offensive')
    # A name that is already a hunt is refused, not written over.
    editor.on_rename('plains')
    editor.on_save
    expect(editor.status_error).to be(true)
    expect(editor.status).to include('already exists')
  end

  it 'saves, keeps the returned revision, and saves again without a conflict' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_save).to be(true)
    expect(editor.status_error).to be(false)
    first = editor.revision
    expect(first).to be_a(String)
    expect(editor).not_to be_dirty

    editor.on_change('hunting_stance', 'defensive')
    editor.on_save
    expect(editor.status_error).to be(false)
    expect(editor.revision).not_to eq(first)
    expect(editor.profiles).to include('forest')
  end

  it 'opens a Bigshot profile with its settings where the controls read them' do
    legacy = File.join(@directory, 'GSIV', 'Example', 'bigshot_profiles')
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, 'old.yaml'), { 'hunting_room_id' => '29902', 'flee_count' => '3' }.to_yaml)
    editor.on_copy_legacy('old')
    expect(editor.settings).to include('hunting_room_id' => '29902', 'flee_count' => '3')
    expect(editor.draft['schema_version']).to eq(1)
    expect(editor.changes.map { |change| change['key'] }).to include('hunting_room_id')
  end

  it 'leaves out what eohunter does not read, and empty values' do
    legacy = File.join(@directory, 'GSIV', 'Example', 'bigshot_profiles')
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, 'old.yaml'),
               { 'flee_count' => '3', 'wand' => '', 'profile_current' => 'old', 'monitor_strings' => 'x' }.to_yaml)
    editor.on_copy_legacy('old')
    expect(editor.settings.keys).to contain_exactly('flee_count')
    expect(editor.status).to include('Left out 2 Bigshot settings')
  end

  it 'counts nothing left out when every setting is one eohunter reads' do
    legacy = File.join(@directory, 'GSIV', 'Example', 'bigshot_profiles')
    FileUtils.mkdir_p(legacy)
    File.write(File.join(legacy, 'old.yaml'), { 'flee_count' => '3' }.to_yaml)
    editor.on_copy_legacy('old')
    expect(editor.status).not_to include('Left out')
  end

  # The hunter reads a saved hunt the way eohunter.lic does: Composition
  # flattens it, and Profile reads what comes out.
  it 'saves a hunt the hunter reads back with its settings' do
    editor.on_new
    editor.on_rename('saved')
    editor.on_change('flee_count', '4')
    editor.on_change('hunting_room_id', '29902')
    editor.on_save
    path = File.join(@directory, 'GSIV', 'Example', 'eohunter', 'profiles', 'saved.yaml')
    expect(File).to exist(path)
    profile = EO::Engine::Profile.new(EO::HunterSetup::Composition.read_profile(path), name: 'saved')
    expect(profile['flee_count']).to eq(4)
    expect(profile['hunting_room_id']).to eq(29902)
  end

  it 'refuses to save an unnamed draft rather than writing one' do
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_save).to be(true)
    expect(editor.status_error).to be(true)
    expect(editor.profiles).to be_empty
  end

  it 'reports a save conflict instead of overwriting a document edited elsewhere' do
    editor.on_rename('forest')
    editor.on_save
    other = described_class.new(app: app)
    other.on_load('forest')
    other.on_change('flee_count', '3')
    other.on_save
    expect(other.status_error).to be(false)

    editor.on_change('flee_count', '9')
    editor.on_save
    expect(editor.status_error).to be(true)
    expect(editor.status).to match(/reload/i)
  end

  it 'loads a saved hunt back into a clean draft' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    editor.on_save

    fresh = described_class.new(app: app)
    fresh.on_load('forest')
    expect(fresh.name).to eq('forest')
    expect(fresh.settings).to include('hunting_stance' => 'offensive')
    expect(fresh).not_to be_dirty
  end

  it 'reverts to the last saved state' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    editor.on_save
    editor.on_change('hunting_stance', 'defensive')
    editor.on_revert
    expect(editor.settings).to include('hunting_stance' => 'offensive')
    expect(editor).not_to be_dirty
  end

  it 'validates without saving and keeps the report' do
    editor.on_rename('forest')
    editor.on_change('hunting_stance', 'offensive')
    expect(editor.on_validate).to be(true)
    expect(editor.validation).not_to be_nil
    expect(editor.profiles).to be_empty
  end

  describe 'list-shaped settings' do
    # The engine's split/rooms cleaners split a String. Handed an Array they
    # stringify it, so ["101"] comes back as ["[\"101\"]"] -- a silent
    # corruption. Everything list-shaped is therefore stored as text.
    it 'keeps a comma list as text through a save and reload' do
      editor.on_rename('forest')
      editor.on_change('hunting_scripts', 'first, second')
      editor.on_save
      reloaded = described_class.new(app: app)
      reloaded.on_load('forest')
      expect(reloaded.settings['hunting_scripts']).to eq('first, second')
      expect(EO::Engine::Profile.new(reloaded.settings).settings['hunting_scripts'])
        .to eq(%w[first second])
    end

    it 'stores map-assigned boundaries as text the engine reads back as room ids' do
      editor.on_assign_room('hunting_boundaries', 101)
      editor.on_assign_room('hunting_boundaries', 202)
      expect(editor.settings['hunting_boundaries']).to be_a(String)
      expect(EO::Engine::Profile.new(editor.settings).settings['hunting_boundaries'])
        .to eq([101, 202])
    end

    it 'removes a boundary the map clears, and drops the setting when none are left' do
      editor.on_assign_room('hunting_boundaries', 101)
      editor.on_assign_room('hunting_boundaries', 101)
      expect(editor.settings).not_to have_key('hunting_boundaries')
    end
  end

  describe 'ordered list editing' do
    it 'adds, reorders and removes entries, keeping order meaningful' do
      editor.on_list_add('hunting_scripts', 'first')
      editor.on_list_add('hunting_scripts', 'second')
      editor.on_list_add('hunting_scripts', 'third')
      expect(editor.list_entries('hunting_scripts')).to eq(%w[first second third])

      editor.on_list_move('hunting_scripts', 2, -1)
      expect(editor.list_entries('hunting_scripts')).to eq(%w[first third second])

      editor.on_list_remove('hunting_scripts', 0)
      expect(editor.list_entries('hunting_scripts')).to eq(%w[third second])
    end

    it 'ignores a blank addition and a move off either end' do
      editor.on_list_add('hunting_scripts', '  ')
      expect(editor.settings).not_to have_key('hunting_scripts')
      editor.on_list_add('hunting_scripts', 'only')
      expect(editor.on_list_move('hunting_scripts', 0, -1)).to be(false)
      expect(editor.on_list_move('hunting_scripts', 0, 1)).to be(false)
      expect(editor.list_entries('hunting_scripts')).to eq(['only'])
    end

    it 'drops an entry that is blanked, and the setting once it is empty' do
      editor.on_list_add('hunting_scripts', 'one')
      editor.on_list_set('hunting_scripts', 0, '')
      expect(editor.settings).not_to have_key('hunting_scripts')
    end

    it 'reads an existing comma setting as entries' do
      editor.on_change('hunting_scripts', 'a, b , c')
      expect(editor.list_entries('hunting_scripts')).to eq(%w[a b c])
    end
  end

  describe 'search' do
    it 'matches on every term, across key, label, help and legacy aliases' do
      editor.on_search('flee count')
      expect(editor.search_results.map { |field| field['key'] }).to include('flee_count')
      editor.on_search('zzzznothing')
      expect(editor.search_results).to be_empty
    end

    it 'returns nothing for an empty query rather than everything' do
      editor.on_search('   ')
      expect(editor.query).to eq('')
      expect(editor.search_results).to be_empty
    end
  end

  describe 'unsaved changes' do
    it 'lists what a save would change, with what it changes from' do
      editor.on_rename('forest')
      editor.on_change('hunting_stance', 'offensive')
      editor.on_save
      expect(editor.changes).to be_empty

      editor.on_change('hunting_stance', 'defensive')
      editor.on_change('flee_count', '3')
      expect(editor.changes).to contain_exactly(
        { 'key' => 'flee_count', 'before' => nil, 'after' => '3' },
        { 'key' => 'hunting_stance', 'before' => 'offensive', 'after' => 'defensive' }
      )
    end

    it 'shows a cleared setting as a change, not as absent' do
      editor.on_rename('forest')
      editor.on_change('hunting_stance', 'offensive')
      editor.on_save
      editor.on_change('hunting_stance', '')
      expect(editor.changes).to contain_exactly(
        { 'key' => 'hunting_stance', 'before' => 'offensive', 'after' => nil }
      )
    end
  end

  describe 'document management' do
    before do
      editor.on_rename('forest')
      editor.on_save
      editor.on_new
      editor.on_rename('marsh')
      editor.on_save
    end

    it 'sets and clears the hunt an argument-free ;eohunter would start' do
      editor.on_set_active('forest')
      expect(editor.active_profile).to eq('forest')
      expect(editor.status).to match(/did not start/i)
      editor.on_set_active(nil)
      expect(editor.active_profile).to be_nil
    end

    it 'hides and restores a name without touching the profile' do
      editor.on_set_hidden('marsh', true)
      expect(editor).to be_hidden('marsh')
      expect(editor.profiles).to include('marsh')
      editor.on_set_hidden('marsh', false)
      expect(editor).not_to be_hidden('marsh')
    end

    it 'deletes only after confirmation, and clears the draft it was editing' do
      editor.on_load('marsh')
      editor.on_request_delete('marsh')
      expect(editor.pending_delete).to include(name: 'marsh')
      expect(editor.profiles).to include('marsh')
      editor.on_confirm_delete
      expect(editor.profiles).not_to include('marsh')
      expect(editor.name).to eq('')
      expect(editor.revision).to be_nil
    end

    it 'keeps the document when the confirmation is declined' do
      editor.on_request_delete('marsh')
      editor.on_cancel_delete
      expect(editor.pending_delete).to be_nil
      expect(editor.profiles).to include('marsh')
    end

    it 'refuses to delete the default hunt' do
      editor.on_set_active('marsh')
      editor.on_request_delete('marsh')
      editor.on_confirm_delete
      expect(editor.status_error).to be(true)
      expect(editor.profiles).to include('marsh')
    end

    it 'refuses a delete whose document changed after the confirmation was raised' do
      editor.on_request_delete('marsh')
      pending_revision = editor.pending_delete[:revision]
      other = described_class.new(app: app)
      other.on_load('marsh')
      other.on_change('flee_count', '2')
      other.on_save
      editor.on_delete('marsh', pending_revision)
      expect(editor.status_error).to be(true)
      expect(editor.profiles).to include('marsh')
    end

    it 'starts a clean draft that writes nothing until saved' do
      editor.on_load('forest')
      editor.on_new
      expect(editor.name).to eq('')
      expect(editor.settings).to be_empty
      expect(editor).not_to be_dirty
      expect(editor.profiles).to contain_exactly('forest', 'marsh')
    end
  end

  it 'surfaces a validation error rather than raising out of a handler' do
    editor.on_change('flee_count', 'not a number')
    editor.on_validate
    expect(editor.status).to be_a(String)
  end

  # A hunt that cannot be opened used to report the raw store error and leave
  # the row in place, so the button read as dead: clicking it again failed the
  # same way with the same wording, and nothing said which hunt was meant.
  # The editor opens before the game has been asked for a ready list or an
  # inventory: ReadyList.check waits out roundtime and then for the game to
  # answer, and Inventory.refresh waits up to five seconds on the _inventory
  # manager exchange. Doing either first meant the window appeared and nothing
  # in it responded until the game replied.
  describe 'equipment that arrives after the editor has opened' do
    it 'offers the pickers nothing until it knows what the character has' do
      editor = described_class.new(app: app)
      labels = editor.equipment_options('hunting_right_hand').map { |option| option['label'] }
      expect(labels).to contain_exactly('Leave the hand alone', 'Empty the hand')
    end

    it 'offers what arrived once it does' do
      editor = described_class.new(app: app)
      editor.equipment = {
        ready_list: { 'weapon' => { noun: 'bow', name: 'a scorched glowbark long bow' } },
        inventory: [{ noun: 'knife', name: 'a narrow vultite knife', types: nil }]
      }
      labels = editor.equipment_options('hunting_right_hand').map { |option| option['label'] }
      expect(labels).to include('[W] scorched glowbark long bow')
    end

    # The armament tables are read once at startup and do not arrive late, so
    # the merge must not drop them.
    it 'keeps everything else the boot knew' do
      editor = described_class.new(app: app)
      before = editor.profiles
      editor.equipment = { ready_list: {}, inventory: [] }
      expect(editor.profiles).to eq(before)
      expect(editor.fields).not_to be_empty
    end
  end

  describe 'opening a hunt that is not there' do
    it 'says which hunt could not be opened, and marks it an error' do
      editor = described_class.new(app: app)
      expect(editor.on_load('Nonexistent')).to be(true)
      expect(editor.status).to include('Nonexistent')
      expect(editor.status).to match(/could not open/i)
      expect(editor.status_error).to be(true)
    end

    it 'rebuilds the list, so a missing hunt stops being offered' do
      editor = described_class.new(app: app)
      editor.on_new
      editor.on_rename('Doomed')
      editor.on_save
      expect(editor.profiles).to include('Doomed')
      path = Dir.glob(File.join(@directory, '**', 'Doomed.yaml')).first
      expect(path).not_to be_nil
      File.delete(path)
      editor.on_load('Doomed')
      expect(editor.profiles).not_to include('Doomed')
    end
  end
end
