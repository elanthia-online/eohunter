# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'EOHunter with the opt-in Lich coordination prototype' do
  before(:context) do
    root = ENV['LICH_COORDINATION_ROOT']
    skip 'set LICH_COORDINATION_ROOT to the paired Lich prototype checkout' if root.nil? || root.empty?
    require File.join(File.expand_path(root), 'lib/internal_api/coordination')
  end

  let(:clock) { [100.0] }
  let(:session) do
    Lich::InternalAPI::Coordination::Session.new(game: 'GS3', character: 'Bob', run_id: 'offline-hunt',
                                                 read_token: 'offline-integration-only', enabled: true, clock: -> { clock.first })
  end
  let(:world) { FakeWorld.new }
  let(:engine) { EO::Engine::Engine.new(world: world, behaviors: [], interval: 0) }
  let(:reader) do
    lambda do |w|
      EO::Engine::Group.report(w, name: 'Bob', rest_policy: EO::Engine::Rest::Policy.new,
                                 counters: EO::Engine::Rest::Counters.new, now: nil)
    end
  end
  let(:adapter) { EO::Engine::Coordination::Adapter.new(publisher: session, report_reader: reader) }
  let(:client) do
    Lich::InternalAPI::Coordination::Client.new(descriptor: session.descriptor,
                                                read_token: 'offline-integration-only', max_age: 1.0)
  end

  before do
    world.me.encumbrance_pct = 0
    world.me.fxp_pct = 0
    world.me.mana_pct = 100
    world.me.spirit = 10
    world.me.stamina_pct = 100
    expect(session.start).to be_truthy
    adapter.attach(engine)
  end

  after do
    session.close
    EO::Engine::Events.reset!
  end

  it 'carries an actual completed Group report over the native transport as unknown readiness' do
    expect(client.snapshot[:ok]).to be false
    engine.tick
    expect(adapter.last_error).to be_nil
    result = client.snapshot
    expect(result[:ok]).to be true
    expect(result[:payload]).to include(identity: session.identity, owner_tick: 1, sequence: 1, ready: false,
                                        connected: nil, room: { id: 1, epoch: nil })
    expect(result[:payload][:readiness]).to include(ready: nil, coherence: 'unknown', roundtime: false,
                                                    looting: false, owner: { state: 'running', behavior: nil })
    expect(world.sent_commands).to be_empty
  end

  it 'keeps endpoint ping and repeated reads from freshening a stalled or stopped owner' do
    engine.tick
    first = client.snapshot.fetch(:payload)
    clock[0] += 3.0
    expect(client.ping).to be true
    stalled = client.snapshot.fetch(:payload)
    expect(stalled).to include(owner_tick: first[:owner_tick], sequence: first[:sequence], ready: false)
    expect(stalled[:age]).to be >= 3.0

    engine.stop!(:offline_test)
    engine.tick
    clock[0] += 2.0
    expect(client.ping).to be true
    stopped = client.snapshot.fetch(:payload)
    expect(stopped).to include(owner_tick: 1, sequence: 1, ready: false)
    expect(stopped[:age]).to be >= 5.0
    expect(world.sent_commands).to be_empty
  end

  it 'fences old readers on reconnect and publishes the next completed tick under the new identity' do
    engine.tick
    old_client = client
    expect(old_client.snapshot[:ok]).to be true
    session.reconnect
    expect(old_client.snapshot[:ok]).to be false
    engine.tick
    current = Lich::InternalAPI::Coordination::Client.new(descriptor: session.descriptor,
                                                          read_token: 'offline-integration-only')
    result = current.snapshot
    expect(result[:ok]).to be true
    expect(result[:payload]).to include(identity: session.identity, owner_tick: 2, ready: false)
    expect(world.sent_commands).to be_empty
  end
end
