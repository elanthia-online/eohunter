# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'EOHunter controller refuge observation' do
  # Load only the real script adapter; loading the full .lic would launch a hunt.
  let(:adapter) do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    method = source[/  def self\.controller_snapshot\(.*?(?=  def self\.run_controlled)/m]
    Module.new.tap { |mod| mod.module_eval(method) }
  end
  let(:owner) { Object.new }
  let(:gameobj) { OpenStruct.new(right_hand: nil, left_hand: nil, targets: [], npcs: [], hidden_targets: []) }

  before do
    stub_const('XMLData', OpenStruct.new(room_count: 1, game: 'TEST', indicator: { 'IconSTANDING' => 'y' }))
    stub_const('Room', OpenStruct.new(current: OpenStruct.new(id: 1000)))
    stub_const('GameObj', gameobj)
    stub_const('Char', OpenStruct.new(name: 'Testmage', health: 100, spirit: 10))
    stub_const('Game', OpenStruct.new(closed?: false))
    stub_const('Lich::Gemstone::Overwatch', OpenStruct.new(hiders?: false))
    allow(Script).to receive(:list).and_return([owner])
    stub_const('Lich::Gemstone::Status', OpenStruct.new(dead?: false))
    stub_const('Lich::Gemstone::Creature', OpenStruct.new(targets: []))
  end

  def snapshot = adapter.controller_snapshot(owner, 'test-session')

  it 'accepts an empty native room roster despite a sticky last-selected combat dropdown' do
    expect(snapshot[:destination_safe]).to be true
    gameobj.hidden_targets = ['99']
    expect(snapshot[:destination_safe]).to be true
  end

  it 'rejects a native hostile room member even without a visible GameObj target' do
    Lich::Gemstone::Creature.targets = [OpenStruct.new(id: '99')]
    expect(snapshot[:destination_safe]).to be false
  end

  it 'rejects a creature Overwatch observed hiding even without a visible target' do
    Lich::Gemstone::Overwatch[:hiders?] = true
    expect(snapshot[:destination_safe]).to be false
  end

  it "reads death from Lich's Status independently of the room roster" do
    Lich::Gemstone::Status[:dead?] = true
    expect(snapshot[:alive]).to be false
    Lich::Gemstone::Status[:dead?] = false

    expect(snapshot[:destination_safe]).to be true
  end

  it 'does not turn a failed native roster read into a safe room' do
    allow(Lich::Gemstone::Creature).to receive(:targets).and_raise('roster unavailable')
    expect { snapshot }.to raise_error('roster unavailable')
  end

  it 'rejects a room transition during observation' do
    allow(Room).to receive(:current).and_return(OpenStruct.new(id: 1000), OpenStruct.new(id: 1001))
    expect(snapshot[:stable]).to be false
  end
end
