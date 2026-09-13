# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe 'strict group movement behaviors' do
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, hidden?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, count: 4, players: []) }
  let(:world) { OpenStruct.new(me: me, room: room, group_nouns: []) }
  let(:leader) do
    double('strict leader', strict_movement?: true, newly_lost: [], solo?: false, roundtime?: false,
                           all_present?: true, movement_pending?: false, movement_ready?: false, cancel_movement!: nil,
                           movement_guard_scope: guard_scope)
  end
  let(:guard_scope) do
    lambda do |policy, &work|
      policy.call("#{$cmd_prefix}north") ? work.call : EO::Engine::Actions::Result.new(status: :skipped, reason: :movement_barrier)
    end
  end
  let(:fight) { [false] }
  let(:muster) { EO::Engine::Behaviors::Muster.new(leader: leader, resting: -> { false }, fight: ->(_world) { fight.first }) }

  it 'keeps the group barrier below return, loot, loadout and maintenance' do
    expect(muster.priority).to eq(45)
  end

  it 'prepares the current room incarnation and rechecks readiness rather than caching success' do
    expect(leader).to receive(:prepare_movement).with(1, room_epoch: 4).and_return(Object.new)
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world).reason).to eq(:prepare_movement)
    allow(leader).to receive_messages(movement_pending?: true, movement_ready?: true)
    expect(muster.wants_control?(world)).to be false
    allow(leader).to receive(:movement_ready?).and_return(false)
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world)).to be_nil
  end

  it 'cancels preparation when combat begins and lets existing combat run' do
    fight[0] = true
    expect(leader).to receive(:cancel_movement!)
    expect(muster.wants_control?(world)).to be false
  end

  it 'does not turn an absent strict roster into a solo hunt' do
    allow(leader).to receive(:solo?).and_return(true)
    allow(leader).to receive(:prepare_movement).and_return(nil)
    expect(muster.wants_control?(world)).to be true
    expect(muster.tick(world)).to be_nil
  end

  it 'consumes only after roundtime settlement, directly before the existing movement action' do
    action = EO::Engine::Actions::GroupMove.new(world, way: 'north', leader: leader)
    allow(action).to receive(:settle_rt) { me[:in_rt?] = true }
    expect(leader).to receive(:consume_movement!).with(world) { expect(me.in_rt?).to be true; false }
    expect(action).not_to receive(:game_move)
    expect(action.call.reason).to eq(:movement_barrier)
  end

  it 'uses the existing Move implementation after consuming exactly once' do
    action = EO::Engine::Actions::GroupMove.new(world, way: 'north', leader: leader)
    allow(action).to receive(:settle_rt)
    expect(leader).to receive(:consume_movement!).with(world).once.ordered.and_return(true)
    expect(action).to(receive(:game_move).with('north').once.ordered { room.count += 1; true })
    expect(action.call).to be_success
  end

  it 'refuses a proc exit without consuming an episode or invoking its commands' do
    exit_proc = -> { raise 'must not execute' }
    action = EO::Engine::Actions::GroupMove.new(world, way: exit_proc, leader: leader)
    allow(action).to receive(:settle_rt)
    expect(leader).not_to receive(:consume_movement!)
    expect(action.call.reason).to eq(:unsupported_group_exit)
  end

  it 'routes a combat-blocked hunting departure through the same final barrier' do
    room.targets = []
    state = EO::Engine::Engage::State.new
    state.combat_blocked_room = 1
    walker = double('walker', next_step: [2, 'north'])
    policy = EO::Engine::Wander::Policy.new(wander_stance: nil)
    wander = EO::Engine::Behaviors::Wander.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new,
                                               walker: walker, state: state, movement: leader)
    expect(leader).to receive(:consume_movement!).with(world).and_return(false)
    expect(wander.tick(world).reason).to eq(:movement_barrier)
  end

  context 'with follower cleanup and completed observations' do
    let(:order) { EO::Engine::Group::Order.new(type: :prepare_move, hunt_id: 'hunt', room: 1, at: Time.now, step_id: 'step') }
    let(:incoming) { [order] }
    let(:idle) { [true] }
    let(:member) { double('strict member', strict_movement?: true, cancel_movement: true, ack_movement: true) }
    let(:assist) { double('assist', stand_down!: false) }
    let(:follow) { double('follow', rejoin!: false) }
    let(:orders) do
      EO::Engine::Behaviors::Orders.new(member: member, policy: EO::Engine::Rest::Policy.new,
                                        assist: assist, follow: follow, movement_idle: ->(_world) { idle.first })
    end

    before { allow(member).to receive(:orders) { incoming.shift(incoming.size) } }

    def accept_prepare
      expect(orders.wants_control?(world)).to be true
      orders.tick(world)
    end

    it 'yields to owned cleanup without standing down or acknowledging early' do
      idle[0] = false
      expect(orders.wants_control?(world)).to be false
      expect(assist).not_to receive(:stand_down!)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'records completion locally and only publishes it on the next owner callback' do
      accept_prepare
      expect(orders.wants_control?(world)).to be false
      expect(orders.publish_movement(world)).to be false
      orders.complete_owner_tick(world, 7, state: :running)
      expect(member).not_to have_received(:ack_movement)
      expect(member).to receive(:ack_movement).with(order, owner_tick: 7, room: 1, room_epoch: 4).and_return(true)
      expect(orders.publish_movement(world)).to be true
    end

    it 'cancels a completed candidate when roundtime begins before publication' do
      accept_prepare
      orders.complete_owner_tick(world, 7, state: :running)
      me[:in_rt?] = true
      expect(member).to receive(:cancel_movement).with(order)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'never acknowledges a paused owner or a changed room incarnation' do
      accept_prepare
      orders.complete_owner_tick(world, 7, state: :held)
      expect(orders.publish_movement(world)).to be false
      room.count += 1
      orders.complete_owner_tick(world, 8, state: :running)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'lets cleanup retain arbitration while a prepared receipt is invalidated' do
      accept_prepare
      orders.complete_owner_tick(world, 7, state: :running)
      idle[0] = false
      expect(orders.wants_control?(world)).to be false
      orders.complete_owner_tick(world, 8, state: :running)
      expect(member).to receive(:cancel_movement).with(order)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'rejects a room change during the local completion capture' do
      accept_prepare
      allow(orders).to receive(:movement_idle?) { room.count += 1; true }
      orders.complete_owner_tick(world, 7, state: :running)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'lets return lifecycle orders supersede a preparation deferred for cleanup' do
      idle[0] = false
      expect(orders.wants_control?(world)).to be false
      incoming << EO::Engine::Group::Order.new(type: :prep_rest, hunt_id: 'hunt', room: 1, at: Time.now)
      expect(orders.wants_control?(world)).to be true
      expect(assist).to receive(:stand_down!)
      expect(orders.tick(world)).to be_success
      expect(orders.wants_control?(world)).to be false
      orders.complete_owner_tick(world, 7, state: :running)
      expect(member).not_to receive(:ack_movement)
      expect(orders.publish_movement(world)).to be false
    end

    it 'preserves normal attack preemption when a new enemy arrives during deferred preparation' do
      idle[0] = false
      expect(orders.wants_control?(world)).to be false
      incoming << EO::Engine::Group::Order.new(type: :attack, hunt_id: 'hunt', room: 1, at: Time.now)
      expect(orders.wants_control?(world)).to be true
      expect(assist).to receive(:attack!)
      expect(orders.tick(world)).to be_nil
      expect(orders.wants_control?(world)).to be false
    end
  end
end
