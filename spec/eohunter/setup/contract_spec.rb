# frozen_string_literal: true

require 'tmpdir'
require_relative '../../../scripts/eohunter/setup/runtime'

EO::HunterSetup::Runtime.load_support(File.expand_path('../../../scripts', __dir__))

# Where Lich keeps its WebUI, when it is installed here: LICH_LIB, else the
# usual places. The page specs draw with a stand-in builder; this draws with
# Lich's own, whose build runs the whole contract -- properties, events,
# slots, placements, grid bounds, identity -- so a page Lich would refuse
# fails here and not in the viewer's window.
LICH_LIB = [ENV.fetch('LICH_LIB', nil), 'G:/lich5/lib', File.expand_path('~/lich5/lib')]
           .compact.find { |dir| File.exist?(File.join(dir, 'webui', 'tree_builder.rb')) }
require File.join(LICH_LIB, 'webui', 'tree_builder') if LICH_LIB

RSpec.describe EO::HunterSetup::Page, 'against Lich\'s WebUI contract' do
  before { skip 'Lich is not installed here; set LICH_LIB to its lib directory' unless LICH_LIB }

  around do |example|
    Dir.mktmpdir('hunter-contract') do |directory|
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
  let(:session) { EO::HunterSetup::Session.new(editor: editor, refresh: -> {}) }

  # Draws the page with Lich's builder and builds it, which validates it.
  def build
    builder = Lich::WebUI::TreeBuilder.new(owner: Object.new, page_id: 'eohunter-setup', title: 'eohunter setup')
    described_class.render(builder, editor, session)
    builder.build
  end

  it 'builds every page, with every fold open and after a check' do
    EO::HunterSetup::Page::GROUPS.values.flatten(1).each { |(heading, _keys, fold)| editor.on_toggle_fold(heading) if fold == :fold }
    EO::HunterSetup::Editor::NAV_ITEMS.each do |item|
      editor.on_show_page(item[:id])
      expect { build }.not_to raise_error, "#{item[:id]} breaks the contract"
    end
    editor.on_validate
    EO::HunterSetup::Editor::NAV_ITEMS.each do |item|
      editor.on_show_page(item[:id])
      expect { build }.not_to raise_error, "#{item[:id]} after a check breaks the contract"
    end
  end

  it 'builds the setting search, with and without results' do
    editor.on_search('stance')
    expect { build }.not_to raise_error
    editor.on_search('no such setting anywhere')
    expect { build }.not_to raise_error
  end

  it 'refuses what Lich would, so a break shows here' do
    builder = Lich::WebUI::TreeBuilder.new(owner: Object.new, page_id: 'p', title: 't')
    expect { builder.text(content: 'x', no_such_property: 1) }.to raise_error(Lich::WebUI::UnknownPropertyError)
  end
end
