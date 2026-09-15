# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'Combat buff recovery through Rest' do
  let(:clock) { OpenStruct.new(now: 100.0) }
  let(:me) do
    OpenStruct.new(fxp_pct: 0, mana_pct: 100, spirit: 10, stamina_pct: 100,
                   encumbrance_pct: 0, dead?: false, in_rt?: false, in_cast_rt?: false, effect_active?: false)
  end
  let(:spell) { double('Spell', name: 'Spell Shield', active?: false, known?: false, affordable?: false) }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 200), spell: { 219 => spell }) }
  let(:raw) do
    { 'resting_room_id' => 100, 'hunting_room_id' => 200, 'field_rest_room_id' => 50, 'encumbered' => 60,
      'field_rest_scripts' => 'ewaggle', 'resting_scripts' => 'town-waggle',
      'combat_buffs' => { 'enabled' => true, 'spells' => { 219 => 'field' } } }
  end
  let(:profile) { EO::Engine::Profile.new(raw) }
  let(:buffs) { EO::Engine::BuffPolicy::Coordinator.new(policy: profile.buff_policy, clock: clock) }
  let(:scripts) { double('Scripts', start: true, running?: false) }
  let(:trips) { [] }
  let(:loot) { nil }
  let(:rest) do
    EO::Engine::Behaviors::Rest.new(policy: profile.rest_policy, buffs: buffs, clock: clock, scripts: scripts,
                                    loot: loot, stance: ->(*) { true }, fog: ->(*) { true },
                                    travel: ->(room) { trips << room; world.room.id = room; true })
  end
  before { me.define_singleton_method(:effect_active?) { |_name| false } }
  after { EO::Engine::Events.reset!; EO::Engine::Travel.reset! }

  def drive(phase, limit: 80)
    limit.times do
      rest.tick(world)
      return if rest.phase == phase
    end
    raise "wanted #{phase}, got #{rest.phase}"
  end

  def start_recovery
    expect(rest.wants_control?(world)).to be true
    rest.tick(world)
  end

  it 'returns to field, runs only field scripts, and resumes only after observed restoration' do
    start_recovery
    expect(rest.rest_site).to eq(:field)
    drive(:resting)
    expect(world.room.id).to eq(50)
    expect(scripts).to have_received(:start).with('ewaggle', nil).once
    expect(scripts).not_to have_received(:start).with('town-waggle', anything)
    allow(spell).to receive(:active?).and_return(true)
    drive(:hunting)
    expect(trips).to eq([50, 200])
  end

  it 'holds safely and fails once if a successful script exit did not restore the required spell' do
    failures = []
    EO::Engine::Events.on(:rest_service_failed) { |event| failures << event.data }
    start_recovery
    drive(:rally_out)
    rest.tick(world)
    expect(world.room.id).to eq(50)
    clock.now += 16
    drive(:service_failed)
    5.times { rest.tick(world) }
    expect(trips).to eq([50])
    expect(failures.size).to eq(1)
    expect(failures.first[:reason]).to include('219')
    expect(scripts).to have_received(:start).with('ewaggle', nil).once
  end

  it 'preflights an initial departure and invokes one safe recovery pass instead of hunting unbuffed' do
    world.room.id = 50
    rest.start!(world)
    drive(:resting)
    expect(scripts).to have_received(:start).with('ewaggle', nil).once
    expect(trips).not_to include(200)
  end

  it 'uses town when field rest is not configured' do
    raw.delete('field_rest_room_id')
    start_recovery
    drive(:resting)
    expect(world.room.id).to eq(100)
    expect(scripts).to have_received(:start).with('town-waggle', nil).once
  end

  it 'lets persistent overweight override a field buff request' do
    me.encumbrance_pct = 70
    rest.wants_control?(world)
    clock.now += 5
    start_recovery
    expect(rest.rest_site).to eq(:town)
  end

  context 'while loot owns a hand transaction' do
    let(:loot) { double('Loot', looting?: true, tick: nil) }

    it 'finishes owned loot before beginning the return' do
      start_recovery
      expect(rest.phase).to eq(:hunting)
      expect(loot).to have_received(:tick).with(world)
      expect(trips).to be_empty
      allow(loot).to receive(:looting?).and_return(false)
      rest.tick(world)
      expect(rest.phase).to eq(:leave)
    end
  end

  it 'does not turn a warning-only loss into a return request' do
    raw['combat_buffs']['spells'][219] = 'warn'
    expect(rest.wants_control?(world)).to be false
  end

  it 'returns again if a required effect is lost between departure phases, without casting along the route' do
    start_recovery
    drive(:resting)
    allow(spell).to receive(:active?).and_return(true)
    drive(:hunting_scripts_own)
    world.room.id = 75
    allow(spell).to receive(:active?).and_return(false)
    drive(:resting)
    expect(world.room.id).to eq(50)
    expect(trips).not_to include(200)
    expect(scripts).to have_received(:start).with('ewaggle', nil).twice
  end

  it 'does not interrupt an in-flight outbound trip to cast or restart travel' do
    allow(spell).to receive(:active?).and_return(true)
    world.room.id = 50
    trip = double('Trip', tick: nil)
    # The public travel seam owns its trip until it completes.
    traveling = EO::Engine::Behaviors::Rest.new(policy: profile.rest_policy, buffs: buffs, clock: clock,
                                                scripts: scripts, stance: ->(*) { true }, travel: ->(*) { trip })
    traveling.start!(world)
    8.times { traveling.tick(world) }
    expect(traveling.phase).to eq(:hunting_room)
    allow(spell).to receive(:active?).and_return(false)
    expect { traveling.tick(world) }.not_to change(traveling, :phase)
  end
end

RSpec.describe EO::Engine::Behaviors::Rest, '#signs_phase?' do
  let(:profile) { EO::Engine::Profile.new({ 'resting_room_id' => 100, 'hunting_room_id' => 200 }) }
  let(:rest) { described_class.new(policy: profile.rest_policy, scripts: double('Scripts', start: true, running?: false)) }

  after { EO::Engine::Events.reset!; EO::Engine::Travel.reset! }

  def phase!(name) = rest.instance_variable_set(:@phase, name)

  it 'wants signs at the hunting room and while hunting' do
    %i[arrived done hunting].each do |phase|
      phase!(phase)
      expect(rest.signs_phase?).to be(true), "expected #{phase} to want signs"
    end
  end

  it 'holds signs at the refuge, on the way home and on the way back out' do
    %i[resting_prep resting_prep_own rested resting leave waypoints resting_room
       hunting_prep hunting_prep_own rally_out rally hunting_scripts hunting_room].each do |phase|
      phase!(phase)
      expect(rest.signs_phase?).to be(false), "expected #{phase} to hold signs"
    end
  end

  it 'holds signs through the rally hold, and wants them in the hunting room hold' do
    phase!(:hold)
    rest.instance_variable_set(:@hold, { why: :before_rally })
    expect(rest.signs_phase?).to be false

    rest.instance_variable_set(:@hold, { why: :at_hunting_room })
    expect(rest.signs_phase?).to be true
  end

  it 'starts a first hunt holding signs, so town prep no longer casts them' do
    rest.start!
    expect(rest.signs_phase?).to be false
  end
end
