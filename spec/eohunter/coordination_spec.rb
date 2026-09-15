# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe EO::Engine::Coordination::Adapter do
  let(:world) { FakeWorld.new }
  let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [], interval: 0) }
  let(:identity) { { game: 'GS3', character: +'Bob', incarnation: 'process-one', connection_generation: 1, run_id: 'hunt-one' } }
  let(:publications) { [] }
  let(:publisher) { double('publisher', identity: identity) }
  let(:report) { EO::Engine::Group::Report.new(room: 1, rt: false, looting: false) }
  let(:report_reader) { ->(_world) { report } }
  let(:movement_reader) { ->(_world) { true } }
  let(:source) do
    { connection_generation: 1, room_epoch: 7, connected: true,
      room: { version: 5, age: 0.1, room_epoch: 7, connection_generation: 1 },
      readiness: nil }
  end
  let(:source_reader) { ->(_world) { source } }
  let(:adapter) do
    described_class.new(publisher: publisher, report_reader: report_reader,
                        movement_reader: movement_reader, source_reader: source_reader)
  end

  before do
    allow(publisher).to receive(:publish) do |**projection|
      publications << projection
      true
    end
  end

  after { EO::Engine::Events.reset! }

  it 'is inert until explicitly attached to an owner' do
    adapter
    engine.tick
    expect(publications).to be_empty
  end

  it 'copies the completed owner tick and keeps independent native reads unknown' do
    adapter.attach(engine)
    engine.tick
    expect(publications.last).to include(owner_tick: 1, sequence: 1, identity: identity, connected: true,
                                         room: { id: 1, epoch: 7 })
    expect(publications.last[:readiness]).to include(ready: nil, coherence: 'unknown', movement_ready: true,
                                                     roundtime: false, looting: false,
                                                     owner: { state: 'running', behavior: nil })
    expect(world.sent_commands).to be_empty
  end

  it 'takes the projection after the chosen behavior has completed its action' do
    action = EO::Engine::Behavior.new
    allow(action).to receive(:wants_control?).and_return(true)
    allow(action).to receive(:tick) { report.rt = true; nil }
    owner = EO::Engine::Engine.new(world: world, behaviors: [action], interval: 0)
    adapter.attach(owner)
    owner.tick
    expect(publications.last[:readiness][:roundtime]).to be true
    expect(publications.last[:readiness][:owner][:behavior]).to eq(action.name)
  end

  it 'reports completed paused turns without claiming running ownership' do
    adapter.attach(engine)
    engine.pause!
    engine.tick
    expect(publications.last[:readiness][:owner][:state]).to eq('held')
    expect(publications.last[:owner_tick]).to eq(1)
  end

  it 'does not complete a turn stopped in a start callback' do
    adapter.attach(engine)
    engine.on_tick { engine.stop!(:requested) }
    engine.tick
    expect(publications).to be_empty
  end

  it 'does not complete a turn whose behavior raised' do
    action = EO::Engine::Behavior.new
    allow(action).to receive(:wants_control?).and_return(true)
    allow(action).to receive(:tick).and_raise('failed turn')
    owner = EO::Engine::Engine.new(world: world, behaviors: [action], interval: 0)
    adapter.attach(owner)
    owner.tick
    expect(publications).to be_empty
    expect(owner.stop_reason).to eq(:engine_error)
  end

  it 'does not make a live publisher advance when the owner stops ticking' do
    adapter.attach(engine)
    engine.tick
    previous = adapter.last_projection
    3.times { publisher.identity }
    expect(adapter.last_projection).to equal(previous)
    expect(publications.size).to eq(1)
    engine.tick
    expect(publications.last).to include(owner_tick: 2, sequence: 2)
  end

  it 'deeply copies mutable reader data before publishing' do
    adapter.attach(engine)
    engine.tick
    old = adapter.last_projection
    identity[:character].replace('Other')
    source[:room][:version] = 900
    report.looting = true
    expect(old[:identity][:character]).to eq('Bob')
    expect(old[:sources][:room][:version]).to eq(5)
    expect(old[:readiness][:looting]).to be false
    expect { old[:readiness][:owner][:state].replace('other') }.to raise_error(FrozenError)
  end

  it 'rejects a room change while the report is captured' do
    allow(report_reader).to receive(:call) { world.id = 2; report }
    adapter.attach(engine)
    engine.tick
    expect(publications).to be_empty
    expect(adapter.last_error).to eq(:mixed_capture)
  end

  it 'rejects a source generation change even if the room number returns unchanged' do
    allow(report_reader).to receive(:call) { source[:room_epoch] += 1; report }
    adapter.attach(engine)
    engine.tick
    expect(publications).to be_empty
    expect(adapter.last_error).to eq(:mixed_capture)
  end

  it 'rejects a connection generation change during capture' do
    allow(report_reader).to receive(:call) { source[:connection_generation] += 1; report }
    adapter.attach(engine)
    engine.tick
    expect(publications).to be_empty
  end

  it 'rejects a publishing incarnation change during capture' do
    allow(report_reader).to receive(:call) { identity[:incarnation] = 'replacement'; report }
    adapter.attach(engine)
    engine.tick
    expect(publications).to be_empty
  end

  it 'rejects an ownership status change during capture' do
    allow(report_reader).to receive(:call) { engine.pause!; report }
    adapter.attach(engine)
    engine.tick
    expect(publications).to be_empty
    expect(adapter.last_error).to eq(:mixed_capture)
  end

  it 'preserves unavailable source, connection and readiness as unknown' do
    pilot = described_class.new(publisher: publisher, report_reader: report_reader)
    pilot.attach(engine)
    engine.tick
    expect(publications.last).to include(connected: nil, room: { id: 1, epoch: nil }, sources: { room: nil, readiness: nil })
    expect(publications.last[:readiness]).to include(ready: nil, movement_ready: nil)
  end

  it 'reports roundtime and owned loot without passing readiness' do
    report.rt = true
    report.looting = true
    adapter.attach(engine)
    engine.tick
    expect(publications.last[:readiness]).to include(ready: nil, roundtime: true, looting: true)
  end

  it 'does not allow source metadata to certify independent World reads as coherent' do
    source[:coherence] = 'coherent'
    adapter.attach(engine)
    engine.tick
    expect(publications.last[:readiness]).to include(ready: nil, coherence: 'unknown')
  end

  it 'does not stop the engine when optional publication fails' do
    allow(publisher).to receive(:publish).and_raise(IOError)
    adapter.attach(engine)
    engine.tick
    expect(engine.stopping?).to be false
    expect(adapter.last_error).to eq(:capture_failed)
  end

  it 'keeps rejected publications from replacing the last accepted projection' do
    adapter.attach(engine)
    engine.tick
    previous = adapter.last_projection
    allow(publisher).to receive(:publish).and_return(false)
    engine.tick
    expect(adapter.last_projection).to equal(previous)
    expect(adapter.last_error).to eq(:publisher_rejected)
  end

  it 'cannot attach to another owner run' do
    adapter.attach(engine)
    expect { adapter.attach(engine) }.to raise_error(ArgumentError, /already attached/)
  end

  it 'reuses the real Group.report and Leader movement predicate without issuing group orders' do
    world.me.encumbrance_pct = 0
    world.me.fxp_pct = 0
    world.me.mana_pct = 100
    world.me.spirit = 10
    world.me.stamina_pct = 100
    hub = EO::Engine::Group::Hub.new
    leader = EO::Engine::Group::Leader.new(hub, name: 'Bob', policy: EO::Engine::Group::Policy.new)
    reader = lambda do |w|
      EO::Engine::Group.report(w, name: 'Bob', rest_policy: EO::Engine::Rest::Policy.new,
                                 counters: EO::Engine::Rest::Counters.new, now: nil)
    end
    allow(world.room).to receive(:players).and_return([])
    allow(world).to receive(:group_nouns).and_return([])
    expect(leader).to receive(:movement_ready?).with(world).and_call_original
    expect(EO::Engine::Group).to receive(:report).and_call_original
    pilot = described_class.new(publisher: publisher, report_reader: reader, movement_reader: leader.method(:movement_ready?))
    pilot.attach(engine)
    engine.tick
    expect(pilot.last_error).to be_nil
    expect(publications.last[:readiness][:movement_ready]).to be true
    expect(world.sent_commands).to be_empty
  end
end
