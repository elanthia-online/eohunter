# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Travel::Trip do
  let(:me) { OpenStruct.new(hidden?: false, dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1) }
  let(:world) { OpenStruct.new(me: me, room: room) }
  let(:scripts) do
    Class.new do
      attr_reader :started, :killed

      def initialize = (@started = []; @killed = []; @running = [])
      def start(name, args) = (@started << [name, args]; @running << name)
      def running?(name) = @running.include?(name)
      def kill(name) = (@killed << name; @running.delete(name))
      def finish!(name) = @running.delete(name)
    end.new
  end
  let(:trip) { described_class.new(200, scripts: scripts) }

  after { EO::Engine::Events.reset!; EO::Engine::Travel.reset! }

  it 'starts go2 once and stays underway while it runs' do
    expect(trip.tick(world)).to be_nil
    expect(trip.tick(world)).to be_nil
    expect(scripts.started).to eq([['go2', '200 --disable-confirm']])
  end

  it 'waits for go2 to finish its arrival cleanup before completing the trip' do
    trip.tick(world)
    room.id = 200
    expect(trip.tick(world)).to be_nil
    expect(scripts.killed).to be_empty

    scripts.finish!('go2')
    result = trip.tick(world)
    expect(result).to be_success
    expect(result.reason).to eq(:arrived)
    expect(scripts.killed).to be_empty
    expect(trip.done?).to be true
  end

  it 'is already there without starting anything' do
    room.id = 200
    expect(trip.tick(world)).to be_success
    expect(scripts.started).to be_empty
  end

  it 'arrives by server uid or map tag as well as map id' do
    room.uid = '77'
    room.tags = ['bank']
    expect(described_class.new('u77', scripts: scripts).tick(world)).to be_success
    expect(described_class.new('u78', scripts: scripts).tick(world)).to be_nil
    expect(described_class.new('bank', scripts: scripts).tick(world)).to be_success
    expect(described_class.new('inn', scripts: scripts).tick(world)).to be_nil
  end

  # go2's Status struct, as Lich::Common::Events delivers it.
  def go2_status(phase:, cause: nil, reason: nil, command: nil)
    OpenStruct.new(phase: phase, cause: cause, reason: reason, command: command)
  end

  it 'ends the trip when go2 blocks on a cause walking cannot fix' do
    events = []
    EO::Engine::Events.on(:travel_blocked) { |e| events << e.data }
    trip.tick(world)
    EO::Engine::Travel.note_status(go2_status(phase: :blocked, cause: :injured,
                                              reason: 'You are in far too much agony to do that.', command: 'search'))

    result = trip.tick(world)
    expect(result).to be_failed
    expect(result.reason).to eq(:could_not_reach)
    expect(trip.blocked_cause).to eq(:injured)
    expect(scripts.killed).to eq(['go2'])
    expect(events.first[:reason]).to match(/far too much agony/)
  end

  it 'stays underway on a block go2 clears by itself' do
    trip.tick(world)
    EO::Engine::Travel.note_status(go2_status(phase: :blocked, cause: :roundtime, reason: '...wait 3 seconds.'))
    expect(trip.tick(world)).to be_nil
    expect(scripts.killed).to be_empty
  end

  it 'does not end a fresh trip on the blocker from a previous one' do
    trip.tick(world)
    EO::Engine::Travel.note_status(go2_status(phase: :blocked, cause: :injured, reason: 'agony'))
    trip.tick(world)
    expect(trip.done?).to be true

    scripts.finish!('go2')
    fresh = described_class.new(300, scripts: scripts)
    expect(fresh.tick(world)).to be_nil
    expect(fresh.done?).to be false
  end

  it 'clears the blocked board when go2 reports progress again' do
    trip.tick(world)
    EO::Engine::Travel.note_status(go2_status(phase: :blocked, cause: :injured, reason: 'agony'))
    EO::Engine::Travel.note_status(go2_status(phase: :moving))
    expect(EO::Engine::Travel.blocked_status).to be_nil
    expect(trip.tick(world)).to be_nil
  end

  it 'counts a go2 that ended short as an attempt and gives up after five' do
    failed = []
    EO::Engine::Events.on(:travel_failed) { |e| failed << e.data[:attempts] }
    trip = described_class.new(200, scripts: scripts, retry_delay: 0)
    12.times do
      trip.tick(world)
      scripts.finish!('go2')
    end
    expect(scripts.started.size).to eq(5)
    expect(trip.status).to eq(:failed)
    expect(failed).to eq([5])
    expect(trip.tick(world).reason).to eq(:could_not_reach)
  end

  it 'waits the retry delay before the next attempt after a go2 that ended short' do
    now = Time.at(1000)
    clock = double('clock')
    allow(clock).to receive(:now) { now }
    trip = described_class.new(200, scripts: scripts, retry_delay: 1, clock: clock)
    trip.tick(world)
    scripts.finish!('go2')
    trip.tick(world) # ended short: counted, not restarted yet
    trip.tick(world)
    expect(scripts.started.size).to eq(1)
    now += 1.5
    trip.tick(world)
    expect(scripts.started.size).to eq(2)
  end

  it 'unhides before leaving' do
    me[:hidden?] = true
    unhide = instance_double(EO::Engine::Actions::Command, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Command).to receive(:new).with(world, command: 'unhide').and_return(unhide)
    trip.tick(world)
  end

  it 'cancels a trip in flight' do
    trip.tick(world)
    trip.cancel!
    expect(scripts.killed).to eq(['go2'])
    expect(trip.tick(world).reason).to eq(:cancelled)
  end

  it 'suspends a trip in flight and resumes it without counting an attempt' do
    suspended = []
    EO::Engine::Events.on(:travel_suspended) { |e| suspended << e.data[:place] }
    trip.tick(world)
    trip.suspend!
    expect(scripts.killed).to eq(['go2'])
    expect(scripts.running?('go2')).to be false
    expect(trip.done?).to be false
    expect(suspended).to eq([200])
    expect(trip.tick(world)).to be_nil
    expect(scripts.started.size).to eq(2)
    expect(trip.attempts).to eq(0)
  end

  it 'suspends nothing when go2 is not running' do
    trip.suspend!
    expect(scripts.killed).to be_empty
    room.id = 200
    trip.tick(world)
    trip.suspend!
    expect(scripts.killed).to be_empty
  end

  it 'takes go2 from another trip still underway' do
    other = described_class.new(300, scripts: scripts)
    other.tick(world)
    trip.tick(world)
    expect(scripts.killed).to eq(['go2'])
    expect(scripts.started.map(&:last)).to eq(['300 --disable-confirm', '200 --disable-confirm'])
    expect(EO::Engine::Travel.active).to equal(trip)
    room.id = 200
    expect(trip.tick(world)).to be_nil
    scripts.finish!('go2')
    trip.tick(world)
    expect(EO::Engine::Travel.active).to be_nil
  end
end

RSpec.describe EO::Engine::Travel do
  let(:world) { OpenStruct.new(me: OpenStruct.new(hidden?: false), room: OpenStruct.new(id: 1)) }
  let(:holder) { Object.new }

  it 'drives a blocking travel lambda the old way' do
    expect(described_class.step(holder, ->(_r) { true }, 5, world)).to eq(:arrived)
    expect(described_class.step(holder, ->(_r) { false }, 5, world)).to eq(:failed)
  end

  it 'drives a trip across ticks and keeps it on the holder until done' do
    trip = instance_double(EO::Engine::Travel::Trip)
    allow(trip).to receive(:tick).and_return(nil, EO::Engine::Actions::Result.new(status: :success))
    travel = ->(_r) { trip }
    expect(described_class.step(holder, travel, 5, world)).to eq(:underway)
    expect(holder.instance_variable_get(:@trip)).to equal(trip)
    expect(described_class.step(holder, travel, 5, world)).to eq(:arrived)
    expect(holder.instance_variable_get(:@trip)).to be_nil
  end

  it 'tells a spent trip apart from one blocking miss' do
    spent = instance_double(EO::Engine::Travel::Trip, tick: EO::Engine::Actions::Result.new(status: :failed, reason: :could_not_reach))
    expect(described_class.step(holder, ->(_r) { spent }, 5, world)).to eq(:could_not_reach)
  end

  it 'suspends the holder\'s trip and leaves it on the holder' do
    trip = instance_double(EO::Engine::Travel::Trip, tick: nil)
    expect(trip).to receive(:suspend!)
    described_class.step(holder, ->(_r) { trip }, 5, world)
    described_class.suspend(holder)
    expect(holder.instance_variable_get(:@trip)).to equal(trip)
  end
end

RSpec.describe 'a supervised trip inside Rest and Wander' do
  let(:me) { OpenStruct.new(fxp_pct: 50, mana_pct: 10, spirit: 10, stamina_pct: 90, encumbrance_pct: 10, dead?: false, in_rt?: false, in_cast_rt?: false, hidden?: false) }
  let(:room) { OpenStruct.new(id: 1, count: 1, targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, claim_mine?: true, foreign_disks: []) }
  let(:trips) { [] }
  let(:travel) do
    lambda do |r|
      t = instance_double(EO::Engine::Travel::Trip)
      allow(t).to receive(:tick) { trips << r; room.id = r; EO::Engine::Actions::Result.new(status: :success) }
      allow(t).to receive(:cancel!)
      t
    end
  end

  before do
    me.define_singleton_method(:debuff_level) { |_n| nil }
    me.define_singleton_method(:debuff_active?) { |_n| false }
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:send_through_ladder).and_return('ok')
    allow_any_instance_of(EO::Engine::Actions::Command).to receive(:sleep)
    world.define_singleton_method(:exits_from) { |_id| { 2 => 'north' } }
  end

  after { EO::Engine::Events.reset! }

  it 'walks Rest through its rooms one trip tick at a time' do
    policy = EO::Engine::Rest::Policy.new(oom: 20, rest_till_mana: 90, rest_till_exp: 100, resting_room: 100, return_waypoints: [7], hunting_room: 200,
                                          rest_interval: 0, fog_return: 0)
    rest = EO::Engine::Behaviors::Rest.new(policy: policy, travel: travel, scripts: double(running?: false, kill: nil, start: nil), stance: ->(_s) { true })
    allow(rest).to receive(:sleep)
    rest.wants_control?(world)
    8.times { rest.tick(world); break if rest.phase == :resting }
    expect(trips).to eq([7, 100])
    me.mana_pct = 95
    10.times { rest.tick(world); break if rest.phase == :hunting }
    expect(trips).to eq([7, 100, 200])
  end

  it 'sends Wander home through a trip' do
    policy = EO::Engine::Wander::Policy.new(hunting_room: 1, boundaries: [], wander_wait: 0)
    area = EO::Engine::Wander::Area.new(start: 1, boundaries: []).build(world)
    wander = EO::Engine::Behaviors::Wander.new(policy: policy, targets_policy: EO::Engine::Targets::Policy.new, area: area,
                                               travel: travel, stance: ->(_s) { true })
    room.id = 50
    expect(wander.tick(world).reason).to eq(:returned_home)
    expect(trips).to eq([1])
  end
end
