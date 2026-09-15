# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe EO::Engine::Engine do
  after { EO::Engine::Events.reset! }

  let(:world) { FakeWorld.new }

  def behavior(priority:, wants:, result: nil, &block)
    b = EO::Engine::Behavior.new
    allow(b).to receive_messages(priority: priority, wants_control?: wants)
    allow(b).to receive(:tick) do |_w|
      block&.call
      result
    end
    b
  end

  it 'gives control to the highest-priority (lowest number) willing behavior' do
    order = []
    urgent = behavior(priority: 0, wants: true) { order << :urgent }
    casual = behavior(priority: 50, wants: true) { order << :casual }
    engine = described_class.new(world: world, behaviors: [casual, urgent], interval: 0)
    engine.tick
    expect(order).to eq([:urgent])
  end

  it 'falls through to lower priority when higher declines' do
    order = []
    urgent = behavior(priority: 0, wants: false) { order << :urgent }
    casual = behavior(priority: 50, wants: true) { order << :casual }
    engine = described_class.new(world: world, behaviors: [urgent, casual], interval: 0)
    engine.tick
    expect(order).to eq([:casual])
  end

  # A muckled character cannot act: every action below Cleanse refuses
  # with :muckled before it sends. A behavior that keeps winning the
  # arbiter through a stun spends the stun refusing itself and starves
  # the ones that could get us out.
  it 'holds every behavior that does not run muckled while we are muckled' do
    ran = []
    maintain = behavior(priority: 40, wants: true) { ran << :maintain }
    engine = described_class.new(world: world, behaviors: [maintain], interval: 0)
    engine.tick
    expect(ran).to eq([:maintain])

    ran.clear
    world.me[:muckled?] = true
    5.times { engine.tick }
    expect(ran).to be_empty

    world.me[:muckled?] = false
    engine.tick
    expect(ran).to eq([:maintain])
  end

  it 'still runs the behaviors that get us out of the muckle' do
    ran = []
    cleanse = behavior(priority: 5, wants: true) { ran << :cleanse }
    allow(cleanse).to receive(:runs_muckled?).and_return(true)
    maintain = behavior(priority: 40, wants: true) { ran << :maintain }
    engine = described_class.new(world: world, behaviors: [cleanse, maintain], interval: 0)
    world.me[:muckled?] = true
    engine.tick
    expect(ran).to eq([:cleanse])
  end

  # The watchdog half: without the hold, five muckled refusals in five
  # ticks stopped a live hunt in about a second with nothing on the wire.
  it 'does not trip the failure watchdog on a stun' do
    refusing = behavior(priority: 40, wants: true,
                        result: EO::Engine::Actions::Result.new(status: :failed, reason: :muckled))
    tripped = []
    EO::Engine::Events.on(:watchdog_tripped) { |e| tripped << e.data }
    engine = described_class.new(world: world, behaviors: [refusing], interval: 0,
                                 max_consecutive_failures: 3)
    world.me[:muckled?] = true
    10.times { engine.tick }
    expect(tripped).to be_empty
  end

  it 'trips the watchdog after N consecutive failed actions, and says what the game refused' do
    failing = behavior(priority: 0, wants: true,
                       result: EO::Engine::Actions::Result.new(status: :timeout, reason: :no_confirmation,
                                                               line: 'You are unable to do that.'))
    tripped = []
    EO::Engine::Events.on(:watchdog_tripped) { |e| tripped << e.data }
    engine = described_class.new(world: world, behaviors: [failing],
                                 interval: 0, max_consecutive_failures: 3)
    3.times { engine.tick }
    expect(engine.stopping?).to be(true)
    expect(engine.stop_reason).to eq(:repeated_failures)
    expect(tripped.first[:count]).to eq(3)
    # the last action's reason is the diagnosis, and it was thrown away
    expect(tripped.first[:reason]).to eq(:no_confirmation)
    expect(tripped.first[:line]).to eq('You are unable to do that.')
  end

  it 'resets the failure count on success' do
    results = [
      EO::Engine::Actions::Result.new(status: :timeout),
      EO::Engine::Actions::Result.new(status: :timeout),
      EO::Engine::Actions::Result.new(status: :success),
      EO::Engine::Actions::Result.new(status: :timeout)
    ]
    flaky = behavior(priority: 0, wants: true)
    allow(flaky).to receive(:tick) { results.shift }
    engine = described_class.new(world: world, behaviors: [flaky],
                                 interval: 0, max_consecutive_failures: 3)
    4.times { engine.tick }
    expect(engine.stopping?).to be(false)
  end

  it 'does not count deliberately skipped routine lines as failed actions' do
    skipped = behavior(
      priority: 0,
      wants: true,
      result: EO::Engine::Actions::Result.new(status: :skipped, reason: :condition)
    )
    engine = described_class.new(world: world, behaviors: [skipped],
                                 interval: 0, max_consecutive_failures: 3)
    5.times { engine.tick }
    expect(engine.stopping?).to be(false)
  end

  # The gate refusals a real action hands back, driven through the real
  # engine. A muckled tick sends nothing, so it is the action declining
  # itself, not the game refusing a command: it must never feed the
  # repeated-failures watchdog. Before Actions::Base#call returned
  # :skipped for its gates, an ordinary stun with a sign or a corpse due
  # stopped a live hunt in about a second with nothing on the wire, while
  # bigshot's bs_put waits the stun out and carries on.
  it 'does not stop the hunt when a real action refuses at its gates' do
    muckled = Class.new(EO::Engine::Actions::Base) do
      def preconditions = :muckled

      def perform = raise('must not perform: the gate refused')
    end
    acting = behavior(priority: 0, wants: true)
    allow(acting).to receive(:tick) { muckled.new(world).call }

    stops = []
    EO::Engine::Events.on(:watchdog_tripped) { |e| stops << e.data }
    engine = described_class.new(world: world, behaviors: [acting],
                                 interval: 0, max_consecutive_failures: 5)
    10.times { engine.tick }

    expect(engine.stopping?).to be(false)
    expect(stops).to be_empty
  end

  describe 'the fire budget' do
    # As Actions::Base hands them back: the stamp says a command went out.
    let(:success) { EO::Engine::Actions::Result.new(status: :success, acted: true) }

    def budgeted(budget, result: success, wants: true)
      b = behavior(priority: 0, wants: wants, result: result)
      allow(b).to receive(:fire_budget).and_return(budget)
      b
    end

    it 'trips when a behavior acts more often inside its window than the budget allows' do
      now = 1000.0
      looper = budgeted([3, 10])
      tripped = []
      EO::Engine::Events.on(:watchdog_tripped) { |e| tripped << e.data }
      engine = described_class.new(world: world, behaviors: [looper], interval: 0, clock: -> { now })
      3.times { engine.tick }
      expect(engine.stopping?).to be(false)
      expect(engine.fire_counts(now)).to eq('behavior' => 3)
      engine.tick
      expect(engine.stop_reason).to eq(:fire_budget)
      expect(tripped.first).to include(kind: :fire_budget, behavior: 'behavior', count: 4)
    end

    it 'forgets fires that slid out of the window' do
      now = 1000.0
      steady = budgeted([3, 10])
      engine = described_class.new(world: world, behaviors: [steady], interval: 0, clock: -> { now })
      3.times { engine.tick; now += 4 }
      engine.tick
      expect(engine.stopping?).to be(false)
      expect(engine.fire_counts(now)).to eq('behavior' => 3)
    end

    it 'counts a sent command that failed as a fire, but not skipped lines or silent ticks' do
      now = 1000.0
      skipper = budgeted([2, 60], result: EO::Engine::Actions::Result.new(status: :skipped, reason: :condition))
      engine = described_class.new(world: world, behaviors: [skipper], interval: 0, clock: -> { now })
      5.times { engine.tick }
      expect(engine.fire_counts(now)).to eq('behavior' => 0)
      quiet = budgeted([2, 60], result: nil)
      engine = described_class.new(world: world, behaviors: [quiet], interval: 0, clock: -> { now })
      5.times { engine.tick }
      expect(engine.stopping?).to be(false)
      flaky = budgeted([2, 60], result: EO::Engine::Actions::Result.new(status: :timeout, acted: true))
      engine = described_class.new(world: world, behaviors: [flaky], interval: 0,
                                   max_consecutive_failures: 10, clock: -> { now })
      3.times { engine.tick }
      expect(engine.stop_reason).to eq(:fire_budget)
    end

    # The Ojandhaart trip: a routine cycling "stance offensive" (already
    # offensive, a no-op success) and "incant 608" (already hidden, a gate
    # refusal) around each real FIRE counted three fires per arrow. The
    # status is the behavior's own account; only the send seam's stamp
    # counts, so a hand-built result of either status is not a fire.
    it 'ignores a result that never reached the game, whatever its status says' do
      now = 1000.0
      results = [
        EO::Engine::Actions::Result.new(status: :success, reason: :stance),
        EO::Engine::Actions::Result.new(status: :failed, reason: :hidden),
        EO::Engine::Actions::Result.new(status: :success, acted: true)
      ]
      cycling = budgeted([2, 60])
      allow(cycling).to receive(:tick) { results.rotate!.last }
      engine = described_class.new(world: world, behaviors: [cycling], interval: 0,
                                   max_consecutive_failures: 10, clock: -> { now })
      6.times { engine.tick }
      expect(engine.stopping?).to be(false)
      expect(engine.fire_counts(now)).to eq('behavior' => 2)
    end

    it 'leaves a behavior with no budget alone' do
      walker = budgeted(nil)
      engine = described_class.new(world: world, behaviors: [walker], interval: 0)
      100.times { engine.tick }
      expect(engine.stopping?).to be(false)
      expect(engine.fire_counts).to eq({})
    end

    it 'defaults to sixty fires a minute, with the trip behaviors opted out' do
      expect(EO::Engine::Behavior.new.fire_budget).to eq([60, 60])
      expect(EO::Engine::Behaviors::Wander.instance_method(:fire_budget).owner).to eq(EO::Engine::Behaviors::Wander)
      expect(EO::Engine::Behaviors::Rest.instance_method(:fire_budget).owner).to eq(EO::Engine::Behaviors::Rest)
    end
  end

  describe 'the arbiter trace' do
    it 'records each guard asked, down to the one that took control' do
      urgent = behavior(priority: 0, wants: false)
      allow(urgent).to receive(:name).and_return('survival')
      middle = behavior(priority: 20, wants: true)
      allow(middle).to receive(:name).and_return('rest')
      below = behavior(priority: 50, wants: true)
      allow(below).to receive(:name).and_return('engage')
      engine = described_class.new(world: world, behaviors: [below, middle, urgent], interval: 0)
      engine.tick
      expect(engine.last_evaluations).to eq([['survival', false], ['rest', true]])
      expect(below).not_to have_received(:wants_control?)
    end

    it 'records every guard when nobody wants control' do
      a = behavior(priority: 0, wants: false)
      b = behavior(priority: 50, wants: false)
      engine = described_class.new(world: world, behaviors: [a, b], interval: 0)
      engine.tick
      expect(engine.last_evaluations.map(&:last)).to eq([false, false])
    end

    it 'rides along on a watchdog trip, so the report says who declined' do
      urgent = behavior(priority: 0, wants: false)
      allow(urgent).to receive(:name).and_return('survival')
      failing = behavior(priority: 50, wants: true, result: EO::Engine::Actions::Result.new(status: :timeout))
      tripped = []
      EO::Engine::Events.on(:watchdog_tripped) { |e| tripped << e.data }
      engine = described_class.new(world: world, behaviors: [urgent, failing], interval: 0, max_consecutive_failures: 2)
      2.times { engine.tick }
      expect(tripped.first[:evaluations]).to eq([['survival', false], ['behavior', true]])
    end
  end

  it 'stops on engine errors instead of grinding' do
    exploder = behavior(priority: 0, wants: true)
    allow(exploder).to receive(:tick).and_raise('unexpected')
    errors = []
    EO::Engine::Events.on(:engine_error) { |e| errors << e.data }
    engine = described_class.new(world: world, behaviors: [exploder], interval: 0)
    engine.tick
    expect(engine.stop_reason).to eq(:engine_error)
    expect(errors.first[:message]).to eq('unexpected')
  end

  it 'propagates native guard interruption to its owner without declaring an engine error or completing the tick' do
    interruption_class = Class.new(StandardError)
    stub_const('Lich::Common::ScriptExecutionGuard::Interrupted', interruption_class)
    interruption = interruption_class.new('checkpoint_rejected')
    exploder = behavior(priority: 0, wants: true) { raise interruption }
    errors, completed = [], []
    EO::Engine::Events.on(:engine_error) { |event| errors << event.data }
    engine = described_class.new(world: world, behaviors: [exploder], interval: 0)
    engine.on_tick_completed { completed << true }

    expect { engine.tick }.to(raise_error { |error| expect(error).to equal(interruption) })
    expect(errors).to be_empty
    expect(completed).to be_empty
  end

  it 'tells the behavior it preempts, once, and again on idle and pause' do
    log = []
    urgent = behavior(priority: 0, wants: false)
    walker = behavior(priority: 50, wants: true)
    walker.define_singleton_method(:preempted!) { |_w| log << :suspended }
    EO::Engine::Events.on(:preempted) { |e| log << [e.data[:from], e.data[:to]] }
    engine = described_class.new(world: world, behaviors: [urgent, walker], interval: 0)
    2.times { engine.tick }
    expect(log).to be_empty
    allow(urgent).to receive(:wants_control?).and_return(true)
    2.times { engine.tick }
    expect(log).to eq([:suspended, ['behavior', 'behavior']])
    allow(urgent).to receive(:wants_control?).and_return(false)
    engine.tick # the walker again
    allow(walker).to receive(:wants_control?).and_return(false)
    engine.tick # idle
    expect(log.last).to eq(['behavior', nil])
    allow(walker).to receive(:wants_control?).and_return(true)
    engine.tick
    engine.pause!
    engine.tick
    expect(log.count(:suspended)).to eq(3)
  end

  it 'acts on nothing after a tick callback stops it' do
    ticked = []
    b = behavior(priority: 0, wants: true) { ticked << :acted }
    engine = described_class.new(world: world, behaviors: [b], interval: 0)
    engine.on_tick { engine.stop!(:leader_lost) }
    engine.tick
    expect(ticked).to be_empty
    expect(engine.stop_reason).to eq(:leader_lost)
  end

  it 'announces each new room before choosing a behavior, so a waiting fight sees a fresh room' do
    seen = []
    EO::Engine::Events.on(:entered_room) { |e| seen << [e.data[:room], :event] }
    fight = behavior(priority: 50, wants: true) { seen << :fight }
    engine = described_class.new(world: world, behaviors: [fight], interval: 0)
    engine.tick
    world.id = 2
    engine.tick
    engine.tick
    expect(seen).to eq([[1, :event], :fight, [2, :event], :fight, :fight])
  end

  it 'run loops until stopped and reports the reason' do
    counter = 0
    b = behavior(priority: 0, wants: true)
    engine = described_class.new(world: world, behaviors: [b], interval: 0)
    allow(b).to receive(:tick) do
      counter += 1
      engine.stop!(:goal_reached) if counter >= 3
      EO::Engine::Actions::Result.new(status: :success)
    end
    expect(engine.run).to eq(:goal_reached)
    expect(counter).to eq(3)
  end
end
