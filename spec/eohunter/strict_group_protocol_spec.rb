# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'Strict group movement protocol' do
  let(:time) { [100.0] }
  let(:leader_identity) { [{ run: 'leader-run', incarnation: 'leader-process', connection_generation: 1 }] }
  let(:member_identity) { [{ run: 'member-run', incarnation: 'member-process', connection_generation: 7 }] }
  let(:native_state) do
    [{ source: { connection_id: 'native-test', sequence: 1, received_at: 100.0 },
       fields: { room: { value: { uid: 1, epoch: 10 } } } }.freeze]
  end
  let(:native_reader) { -> { native_state.first } }
  let(:hub) do
    EO::Engine::Group::Hub.new(strict_movement: true, identity_reader: -> { leader_identity.first }, monotonic: -> { time.first })
  end
  let(:leader) do
    EO::Engine::Group::Leader.new(hub, name: 'Lead', strict_movement: true,
                                 identity_reader: -> { leader_identity.first }, native_reader: native_reader,
                                 movement_idle: ->(_world) { true }, monotonic: -> { time.first })
  end
  let(:member) do
    EO::Engine::Group::Member.new(hub, name: 'Bob', strict_movement: true,
                                 identity_reader: -> { member_identity.first }, native_reader: native_reader)
  end
  let(:world) do
    OpenStruct.new(room: OpenStruct.new(id: 1, count: 10, players: [OpenStruct.new(noun: 'Bob')]),
                   me: OpenStruct.new(in_rt?: false, in_cast_rt?: false, dead?: false, muckled?: false), group_nouns: ['Bob'])
  end

  before do
    hub.open_hunt(leader: 'Lead', expected: ['Bob'])
    expect(member.register).to be true
    hub.activate!
    leader.complete_owner_tick(world, 1, state: :running)
  end

  def prepare
    leader.prepare_movement(1, room_epoch: 10)
  end

  def acknowledge(order, tick: 1, epoch: 90, room: 1)
    member.ack_movement(order, owner_tick: tick, room: room, room_epoch: epoch)
  end

  it 'requires an episode-specific owner preparation and consumes it exactly once' do
    order = prepare
    expect(leader.movement_ready?(world)).to be false
    expect(hub.ack(:prepare_move, 'Bob', hunt_id: hub.hunt_id)).to be false
    expect(acknowledge(order)).to be true
    expect(leader.movement_ready?(world)).to be true
    expect(leader.consume_movement!(world)).to be true
    expect(leader.consume_movement!(world)).to be false
    expect(leader.movement_pending?).to be false
  end

  it 'rejects delayed acknowledgments from an earlier movement in the same room' do
    earlier = prepare
    current = prepare
    expect(acknowledge(earlier)).to be false
    expect(leader.movement_ready?(world)).to be false
    expect(acknowledge(current, tick: 2)).to be true
  end

  it 'does not refresh a duplicate receipt or allow its values to change' do
    order = prepare
    expect(acknowledge(order)).to be true
    time[0] += 0.8
    expect(acknowledge(order)).to be true
    expect(acknowledge(order, epoch: 91)).to be false
    time[0] += 0.3
    leader.complete_owner_tick(world, 2, state: :running)
    expect(leader.movement_ready?(world)).to be false
    expect(acknowledge(order, tick: 2)).to be true
    expect(leader.movement_ready?(world)).to be true
  end

  it 'rejects a replay after cancellation and permits only a later owner turn' do
    order = prepare
    expect(acknowledge(order)).to be true
    expect(member.cancel_movement(order)).to be true
    expect(acknowledge(order)).to be false
    expect(acknowledge(order, tick: 2, epoch: 92)).to be false
    expect(leader.movement_ready?(world)).to be false
    expect(acknowledge(order, tick: 2)).to be true
  end

  it 'retains owner tick watermarks across movement episodes' do
    expect(acknowledge(prepare, tick: 8)).to be true
    current = prepare
    expect(acknowledge(current, tick: 7)).to be false
    expect(acknowledge(current, tick: 8)).to be false
    expect(acknowledge(current, tick: 9)).to be true
  end

  it 'does not compare independent room counters but rejects a changed follower epoch' do
    order = prepare
    expect(acknowledge(order, epoch: 90)).to be true
    expect(acknowledge(order, tick: 2, epoch: 92)).to be false
    world.room.count = 12
    expect(leader.consume_movement!(world)).to be false
  end

  it 'requires the full named roster even before first reports arrive' do
    hub.open_hunt(leader: 'Lead', expected: %w[Bob Ann])
    expect(member.register).to be true
    expect(prepare).to be_nil
    hub.register('Ann', hunt_id: hub.hunt_id, identity: { run: 'ann' })
    current = prepare
    expect(acknowledge(current)).to be true
    expect(leader.movement_ready?(world)).to be false
  end

  it 'rejects same-name replacement identities and unknown participants' do
    order = prepare
    expect { hub.register('Bob', hunt_id: hub.hunt_id, identity: { run: 'replacement' }) }.to raise_error(ArgumentError, /identity changed/)
    expect(hub.acknowledge_movement('Stranger', hunt_id: hub.hunt_id, identity: nil, step_id: order.step_id,
                                  owner_tick: 1, room: 1, room_epoch: 10)).to be false
    expect(hub.acknowledge_movement('Bob', hunt_id: hub.hunt_id, identity: { run: 'replacement' }, step_id: order.step_id,
                                  owner_tick: 1, room: 1, room_epoch: 10)).to be false
  end

  it 'does not let repeated reports or heartbeat extend preparation freshness' do
    order = prepare
    expect(acknowledge(order)).to be true
    time[0] += 1.1
    hub.heartbeat!(room: 1)
    hub.report('Bob', EO::Engine::Group::Report.new(name: 'Bob', room: 1, rt: false))
    leader.complete_owner_tick(world, 2, state: :running)
    expect(leader.movement_ready?(world)).to be false
  end

  it 'does not let a live heartbeat hide stalled or paused leader ownership' do
    order = prepare
    expect(acknowledge(order)).to be true
    time[0] += 1.1
    hub.heartbeat!(room: 1)
    expect(acknowledge(order, tick: 2)).to be true
    expect(leader.movement_ready?(world)).to be false
    leader.complete_owner_tick(world, 2, state: :held)
    expect(leader.movement_ready?(world)).to be false
    leader.complete_owner_tick(world, 3, state: :running)
    expect(leader.movement_ready?(world)).to be true
  end

  it 'expires the episode despite new acknowledgments and requires a new step' do
    order = prepare
    time[0] += 5
    leader.complete_owner_tick(world, 2, state: :running)
    expect(acknowledge(order, tick: 2)).to be false
    expect(leader.movement_pending?).to be false
    expect(acknowledge(prepare, tick: 3)).to be true
  end

  it 'checks leader roundtime and physical membership immediately before consumption' do
    order = prepare
    expect(acknowledge(order)).to be true
    world.me[:in_cast_rt?] = true
    expect(leader.consume_movement!(world)).to be false
    world.me[:in_cast_rt?] = false
    world.group_nouns = []
    expect(leader.consume_movement!(world)).to be false
    world.group_nouns = ['Bob']
    expect(leader.consume_movement!(world)).to be true
  end

  it 'invalidates a follower after its identity disappears even if the old value returns' do
    order = prepare
    original = member_identity.first
    member_identity[0] = nil
    expect(acknowledge(order)).to be false
    member_identity[0] = original
    expect(acknowledge(order, tick: 2)).to be false
    expect(member.leader_alive?).to be false
  end

  it 'invalidates preparation on leader reconnect or finished hunt' do
    order = prepare
    expect(acknowledge(order)).to be true
    leader_identity[0] = leader_identity.first.merge(connection_generation: 2)
    expect(leader.consume_movement!(world)).to be false
    expect(acknowledge(order, tick: 2)).to be false
    hub.leader_finished!(:leader_lost)
    expect(leader.movement_pending?).to be false
  end

  it 'withdraws leader and follower liveness after either exact identity changes' do
    expect(leader.publish(world, phase: :hunting)).to be true
    expect(member.report(EO::Engine::Group::Report.new(name: 'Bob', room: 1, rt: false))).to be true

    leader_identity[0] = leader_identity.first.merge(connection_generation: 2)
    member_identity[0] = member_identity.first.merge(connection_generation: 8)

    expect(leader.publish(world, phase: :hunting)).to be false
    expect(member.report(EO::Engine::Group::Report.new(name: 'Bob', room: 1, rt: false))).to be false
    expect(member.lost?).to be true
  end

  it 'copies participant identities before a caller can mutate them' do
    member_identity.first[:run] = 'different'
    expect(acknowledge(prepare)).to be false
  end

  it 'cannot register a strict member with a legacy hub' do
    legacy = EO::Engine::Group::Hub.new
    legacy.open_hunt(leader: 'Lead', expected: ['Bob'])
    strict = EO::Engine::Group::Member.new(legacy, name: 'Bob', strict_movement: true,
                                          identity_reader: -> { member_identity.first }, native_reader: native_reader)
    expect(strict.register).to be false
    expect(legacy.members).to be_empty
  end

  it 'requires local cleanup authority to be bound and rechecks it on consumption' do
    unbound = EO::Engine::Group::Leader.new(hub, name: 'Lead', strict_movement: true,
                                          identity_reader: -> { leader_identity.first }, native_reader: native_reader,
                                          monotonic: -> { time.first })
    unbound.complete_owner_tick(world, 1, state: :running)
    expect(acknowledge(prepare)).to be true
    expect(unbound.movement_ready?(world)).to be false
    idle = [true]
    unbound.movement_idle = ->(_world) { idle.first }
    expect(unbound.movement_ready?(world)).to be true
    idle[0] = false
    expect(unbound.consume_movement!(world)).to be false
  end

  it 'rejects old-hunt orders and refuses movement after explicit leader loss' do
    order = prepare
    expect(acknowledge(order)).to be true
    hub.leader_finished!(:leader_lost)
    expect(leader.consume_movement!(world)).to be false
    expect(acknowledge(order, tick: 2)).to be false
    hub.open_hunt(leader: 'Lead', expected: ['Bob'])
    expect(member.register).to be true
    expect(acknowledge(order, tick: 3)).to be false
  end

  it 'rejects a movement decision when native publication changes during policy reads' do
    order = prepare
    expect(acknowledge(order)).to be true
    replacement = native_state.first.merge(source: native_state.first[:source].merge(sequence: 2)).freeze
    leader.movement_idle = lambda do |_world|
      native_state[0] = replacement
      true
    end
    expect(leader.consume_movement!(world)).to be false
  end

  it 'rejects a native room publication from another room incarnation' do
    order = prepare
    expect(acknowledge(order)).to be true
    native_state[0] = native_state.first.merge(fields: { room: { value: { uid: 1, epoch: 9 } } }).freeze
    expect(leader.consume_movement!(world)).to be false
  end
end
