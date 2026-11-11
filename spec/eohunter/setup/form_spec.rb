# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

RSpec.describe EO::HunterSetup::Form do
  around do |example|
    Dir.mktmpdir('hunter-form') do |directory|
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

  def field(key) = editor.fields.find { |entry| entry['key'] == key }

  it 'gives every setting a control' do
    kinds = editor.fields.map { |entry| described_class.kind(editor, entry) }
    expect(kinds.uniq - %i[equipment check choice list ruby text_block entry]).to be_empty
  end

  it 'picks the control from the schema' do
    expect(described_class.kind(editor, field('fog_optional'))).to eq(:check)
    expect(described_class.kind(editor, field('fog_return'))).to eq(:choice)
    expect(described_class.kind(editor, field('flee_count'))).to eq(:entry)
    expect(described_class.kind(editor, field('return_waypoint_ids'))).to eq(:list)
    expect(described_class.kind(editor, field('combat_buffs'))).to eq(:text_block)
    expect(described_class.kind(editor, field('hunting_right_hand'))).to eq(:equipment)
    expect(described_class.kind(editor, field('wounded_eval'))).to eq(:ruby)
  end

  it 'parses a structured setting as data, and leaves broken YAML for validation to report' do
    structured = field('combat_buffs')
    expect(described_class.parse(structured, "foo: 1\n")).to eq('foo' => 1)
    expect(described_class.parse(structured, '  ')).to eq('')
    expect(described_class.parse(structured, "foo: [\n")).to eq("foo: [\n")
  end

  it 'passes a scalar through as typed, so the engine cleans it' do
    expect(described_class.parse(field('flee_count'), '3')).to eq('3')
  end

  it 'shows data without the YAML document header' do
    expect(described_class.text('foo' => 1)).to eq("foo: 1\n")
    expect(described_class.text(nil)).to eq('')
  end

  it 'always offers a way to clear a choice' do
    expect(described_class.choices(field('fog_return')).first).to eq(['', '(unset)'])
  end

  it 'labels options the schema gives as plain words' do
    expect(described_class.choices(field('hunting_stance'))).to include(%w[offensive offensive])
  end

  it 'selects an option whatever its case, and keeps a value that is no option' do
    stance = field('hunting_stance')
    options = described_class.choices(stance, 'Offensive')
    expect(described_class.chosen(options, 'Offensive')).to eq('offensive')
    odd = described_class.choices(stance, 'sideways')
    expect(described_class.chosen(odd, 'sideways')).to eq('sideways')
  end

  it 'says where a value comes from' do
    expect(described_class.provenance(editor, field('flee_count'))).to eq('Engine default')
    editor.on_change('flee_count', '3')
    expect(described_class.provenance(editor, field('flee_count'))).to eq('Set in this hunt')
  end

  it 'finds the validation messages for one setting' do
    editor.on_change('combat_buffs', { 'foo' => 1 })
    editor.on_validate
    expect(described_class.messages(editor, 'combat_buffs')).not_to be_empty
    expect(described_class.messages(editor, 'flee_count')).to be_empty
  end
end
