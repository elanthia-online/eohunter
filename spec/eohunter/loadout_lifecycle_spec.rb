# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'Loadout lifecycle' do
  let(:world) { FakeWorld.new }
  let(:policy) { EO::Engine::Loadout::Policy.new(right: 'ready:weapon', left: 'empty') }
  let(:adapter) { instance_double(EO::Engine::Loadout::Core, ready_item: nil) }
  let(:loadout) { EO::Engine::Behaviors::Loadout.new(policy: policy, owner: nil, adapter: adapter) }
  let(:rest_policy) { EO::Engine::Rest::Policy.new(resting_room: 10) }
  let(:rest) do
    EO::Engine::Behaviors::Rest.new(policy: rest_policy, stance: ->(_) {},
                                    travel: ->(room) { world.id = room; true })
  end
  let(:wire) do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    body = source[/  def self\.wire\(.*?(?=  def self\.build\()/m]
    Module.new.tap do |mod|
      mod.const_set(:E, EO::Engine)
      mod.define_singleton_method(:msg) { |*| }
      mod.module_eval(body)
    end
  end

  before do
    world.me.encumbrance_pct = 0
    world.me.fxp_pct = 0
    allow(adapter).to receive(:reconcile).and_raise('could not find Item[:weapon]')
  end

  after do
    EO::Engine::Events.reset!
    EO::Engine::Travel.reset!
    # wire sets the engine-wide interrupt, and it is module state: the
    # script's own before_dying clears it for the same reason (eohunter.lic).
    # Left set, the lambda closes over this example's engine and every later
    # action anywhere in the suite reads it as "stopping".
    EO::Engine::Actions::Base.interrupt = nil
  end

  it 'establishes hands after preparation and before outbound rally travel on every departure' do
    world.id = 10
    wanted = FakeWorld::FakeHand.new('staff', 'staff', nil)
    allow(adapter).to receive(:ready_item).with(:weapon).and_return(wanted)
    allow(adapter).to receive(:reconcile) do
      world.right_id = 'staff'
      world.left_id = nil
    end
    departures = []
    policy = EO::Engine::Rest::Policy.new(resting_room: 10, hunting_room: 30, rally_rooms: [20])
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, stance: ->(_) {}, travel: lambda { |room|
      departures << [room, world.right_id, world.left_id]
      world.id = room
      true
    })
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: policy, loadout: loadout)

    2.times do
      world.id = 10
      world.right_id = 'book'
      world.left_id = 'chalk'
      rest.start!
      30.times { engine.tick; break if rest.phase == :hunting }
    end

    expect(departures).not_to be_empty
    expect(departures).to all(satisfy { |_room, right, left| right == 'staff' && left.nil? })
    expect(adapter).to have_received(:reconcile).twice
  end

  it 'stops at refuge without outbound travel when departure equipment cannot be found' do
    world.id = 10
    policy = EO::Engine::Rest::Policy.new(resting_room: 10, hunting_room: 30)
    travel = double('outbound travel')
    expect(travel).not_to receive(:call)
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, travel: travel, stance: ->(_) {})
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: policy, loadout: loadout)
    rest.start!
    20.times { engine.tick; break if engine.stopping? }

    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(world.room.id).to eq(10)
    expect(adapter).to have_received(:reconcile).once
  end

  it 'rechecks after hunting scripts change hands, before leaving the rally point' do
    world.id = 10
    wanted = FakeWorld::FakeHand.new('staff', 'staff', nil)
    allow(adapter).to receive(:ready_item).with(:weapon).and_return(wanted)
    allow(adapter).to receive(:reconcile) { world.right_id = 'staff'; world.left_id = nil }
    scripts = double('prep scripts', running?: false)
    allow(scripts).to receive(:start) { world.right_id = 'book' }
    departures = []
    policy = EO::Engine::Rest::Policy.new(resting_room: 10, hunting_room: 30, rally_rooms: [20], hunting_scripts: ['prep'])
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, scripts: scripts, stance: ->(_) {}, travel: lambda { |room|
      departures << [room, world.right_id]
      world.id = room
      true
    })
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: policy, loadout: loadout)
    rest.start!
    30.times { engine.tick; break if rest.phase == :hunting }

    expect(departures).to eq([[20, 'staff'], [30, 'staff']])
    expect(scripts).to have_received(:start).with('prep', nil)
    expect(adapter).to have_received(:reconcile).twice
  end

  it 'returns through Rest if departure equipment fails away from refuge' do
    world.id = 20
    destinations = []
    policy = EO::Engine::Rest::Policy.new(resting_room: 10, hunting_room: 30)
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, stance: ->(_) {}, travel: lambda { |room|
      destinations << room
      world.id = room
      true
    })
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: policy, loadout: loadout)
    rest.start!
    30.times { engine.tick; break if engine.stopping? }

    expect(destinations).to eq([10])
    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(adapter).to have_received(:reconcile).once
  end

  it 'uses real Rest to return after one failure, then stops before another hunt' do
    combat = EO::Engine::Behavior.new
    allow(combat).to receive(:wants_control?).and_return(true)
    allow(combat).to receive(:tick)
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout, combat], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: rest_policy, loadout: loadout)

    30.times do
      engine.tick
      break if engine.stopping?
    end

    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(world.room.id).to eq(10)
    expect(rest.phase).to eq(:resting)
    expect(adapter).to have_received(:reconcile).once
    expect(combat).not_to have_received(:tick)
  end

  it 'discards a suspended outbound trip when loadout failure requests return' do
    world.id = 20
    scripts = double('travel scripts', start: nil, running?: true, kill: nil)
    trip = EO::Engine::Travel::Trip.new(30, scripts: scripts, unhide: false)
    trip.tick(world)
    trip.suspend!
    destinations = []
    rest = EO::Engine::Behaviors::Rest.new(policy: rest_policy, stance: ->(_) {}, travel: lambda { |room|
      destinations << room
      world.id = room
      true
    })
    rest.instance_variable_set(:@phase, :hunting_room)
    rest.instance_variable_set(:@trip, trip)
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: rest_policy, loadout: loadout)
    30.times { engine.tick; break if engine.stopping? }

    expect(trip.status).to eq(:cancelled)
    expect(destinations).to eq([10])
    expect(engine.stop_reason).to eq(:loadout_stuck)
  end

  it 'reports failed return after native stranded cleanup instead of restarting or idling forever' do
    world.id = 20
    clock = double('clock')
    now = 0
    allow(clock).to receive(:now) { now += 100 }
    failed_trip = double('exhausted Trip', tick: EO::Engine::Actions::Result.new(status: :failed, reason: :could_not_reach))
    rest = EO::Engine::Behaviors::Rest.new(policy: rest_policy, stance: ->(_) {}, clock: clock, travel: ->(_) { failed_trip })
    engine = EO::Engine::Engine.new(world: world, behaviors: [rest, loadout], interval: 0)
    wire.wire(engine, rest: rest, rest_policy: rest_policy, loadout: loadout)
    150.times { engine.tick; break if engine.stopping? }

    expect(engine.stop_reason).to eq(:loadout_return_failed)
    expect(rest.phase).to eq(:resting)
    expect(world.room.id).to eq(20)
    expect(adapter).to have_received(:reconcile).once
  end

  it 'reports a follower failure through Orders and uses the leader refuge, not its blank personal setting' do
    member = instance_double(EO::Engine::Group::Member, rooms: { resting: 20 }, orders: [], leader_phase: :hunting, strict_movement?: false)
    follower_policy = EO::Engine::Rest::Policy.new
    orders = EO::Engine::Behaviors::Orders.new(member: member, policy: follower_policy)
    engine = EO::Engine::Engine.new(world: world, behaviors: [orders, loadout], interval: 0)
    wire.wire(engine, rest: orders, rest_policy: follower_policy, member: member, loadout: loadout)

    8.times { engine.tick }
    expect(engine.stopping?).to be false
    expect(orders.forced_reason).to include('could not find')
    expect(adapter).to have_received(:reconcile).once

    world.id = 20
    allow(orders).to receive(:rest_prep_done).and_return(true) # stale completion from an earlier rest
    engine.tick
    expect(engine.stopping?).to be false # the return's equipment/prep cleanup still owns the hands
    EO::Engine::Events.emit(:order, type: :resting_prep)
    engine.tick
    expect(engine.stop_reason).to eq(:loadout_stuck)
    expect(world.room.id).to eq(20)
  end

  [EO::Engine::Behaviors::Loot, EO::Engine::Behaviors::Cleanse, EO::Engine::Behaviors::Flee].each do |klass|
    it "waits for #{klass.name.split('::').last} to release control before restoring hands" do
      owner = klass.allocate
      allow(owner).to receive(:wants_control?).and_return(true, false)
      allow(owner).to receive(:tick)
      engine = EO::Engine::Engine.new(world: world, behaviors: [owner, loadout], interval: 0)
      engine.tick
      expect(adapter).not_to have_received(:reconcile)
      engine.tick
      expect(adapter).to have_received(:reconcile).once
    end
  end

  it 'lets an active go2 finish its destination cleanup without preempting it' do
    scripts = double('travel scripts', start: nil, running?: true, kill: nil)
    trip = EO::Engine::Travel::Trip.new(30, scripts: scripts, unhide: false)
    traveler = EO::Engine::Behavior.new
    allow(traveler).to receive(:priority).and_return(60)
    allow(traveler).to receive(:wants_control?).and_return(true)
    allow(traveler).to receive(:tick) { trip.tick(world) }
    traveler.define_singleton_method(:preempted!) { |_| trip.suspend! }
    trip.tick(world)
    engine = EO::Engine::Engine.new(world: world, behaviors: [loadout, traveler], interval: 0)
    engine.tick
    world.id = 30
    engine.tick
    expect(adapter).not_to have_received(:reconcile)
    expect(scripts).not_to have_received(:kill)
    allow(scripts).to receive(:running?).and_return(false)
    engine.tick
    engine.tick
    expect(adapter).to have_received(:reconcile).once
    expect(scripts).not_to have_received(:kill)
  end
end
