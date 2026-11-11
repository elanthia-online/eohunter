# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Trace::Settings do
  def apply(words, from = {}) = described_class.apply(from, words)

  it 'fills defaults in and drops what it does not know' do
    expect(described_class.from(nil)).to eq('on' => false, 'categories' => 'all', 'tick' => false, 'feed' => false, 'file' => false)
    expect(described_class.from('on' => true, 'junk' => 1)['on']).to be true
    expect(described_class.from('on' => true)).not_to have_key('junk')
  end

  it 'turns on and off' do
    expect(apply(%w[on])['on']).to be true
    expect(apply(%w[off], 'on' => true)['on']).to be false
    expect(apply([])['on']).to be false
    expect(apply(%w[status], 'on' => true)['on']).to be true
  end

  it 'names categories, which also turns the trace on' do
    s = apply(%w[combat])
    expect(s['on']).to be true
    expect(s['categories']).to eq(['combat'])
    s = apply(%w[group on], s)
    expect(s['categories']).to eq(%w[combat group])
    s = apply(%w[combat,group,rest], 'categories' => [])
    expect(s['categories']).to eq(%w[combat group rest])
  end

  it 'takes a category away without turning the trace off' do
    s = apply(%w[group off], 'on' => true, 'categories' => %w[combat group])
    expect(s).to include('on' => true, 'categories' => ['combat'])
    s = apply(%w[rest off], 'on' => true, 'categories' => 'all')
    expect(s['categories']).to eq((EO::Engine::Trace::NAMES - [:rest]).map(&:to_s))
  end

  it 'collapses every category back to all' do
    s = apply(%w[rest], 'on' => true, 'categories' => (EO::Engine::Trace::NAMES - [:rest]).map(&:to_s))
    expect(s['categories']).to eq('all')
    expect(apply(%w[all], 'categories' => ['combat'])).to include('on' => true, 'categories' => 'all')
  end

  it 'toggles the switches, or sets them' do
    expect(apply(%w[tick])['tick']).to be true
    expect(apply(%w[tick], 'tick' => true)['tick']).to be false
    expect(apply(%w[file on])['file']).to be true
    expect(apply(%w[feed off], 'feed' => true)['feed']).to be false
    expect(apply(%w[file])['on']).to be false # a switch alone does not turn the trace on
  end

  it 'reads the launch word form' do
    expect(apply(%w[debug=combat,movement])).to include('on' => true, 'categories' => %w[combat movement])
  end

  it 'refuses a word it does not know, naming the choices' do
    expect { apply(%w[cobmat]) }.to raise_error(ArgumentError, /unknown word cobmat.*combat/)
    expect { apply(%w[tick combat]) }.to raise_error(ArgumentError, /expected on or off/)
  end

  it 'describes itself' do
    expect(described_class.describe(nil)).to eq('debug off')
    expect(described_class.describe('file' => true)).to eq('debug off (file on)')
    expect(described_class.describe('tick' => true, 'file' => true)).to eq('debug off (tick, file on)')
    expect(described_class.describe('on' => true)).to eq('debug on: all')
    expect(described_class.describe('on' => true, 'categories' => %w[combat group], 'tick' => true, 'file' => true))
      .to eq('debug on: combat,group + tick, file')
    expect(described_class.describe('on' => true, 'categories' => [])).to eq('debug on: no categories')
  end
end

RSpec.describe EO::Engine::Trace do
  it 'files every emitted event type under a category' do
    all = described_class::CATEGORIES.values.flatten
    expect(all.uniq.size).to eq(all.size)
    expect(described_class.category_of(:engaged)).to eq(:combat)
    expect(described_class.category_of(:never_heard_of)).to eq(:engine)
  end

  it 'formats a payload as k=v, quoting strings with spaces' do
    text = described_class.format_data(target: '#223891', name: 'greater kappa', hp: 61, status: :prone, resources: { mana: 84 },
                                       declined: %i[rest loot], gone: nil, ok: true)
    expect(text).to eq('target=#223891 name="greater kappa" hp=61 status=prone resources=mana:84 declined=rest,loot gone=- ok=true')
  end

  it 'trims a long string and flattens its whitespace' do
    long = "You swing a vultite claidhmore at a greater kappa!\n   #{'x' * 200}"
    text = described_class.format_value(long)
    expect(text).to start_with('"You swing a vultite claidhmore at a greater kappa! xxx')
    expect(text).to end_with('..."')
    expect(text.length).to be <= described_class::VALUE_WIDTH + 2
  end

  it 'formats an event with the time, category and room columns' do
    event = EO::Engine::Events::Event.new(type: :engaged, data: { target: '1', name: 'kobold', routine: 'a' }, at: Time.at(1000, 500_000))
    line = described_class.format_event(event, room: 8030)
    expect(line).to match(/\A\d\d:\d\d:\d\d\.500 combat   8030   engaged target=1 name=kobold routine=a\z/)
    expect(described_class.format_event(event)).to include(' -      engaged')
  end
end

RSpec.describe EO::Engine::Trace::Session do
  let(:lines) { [] }
  let(:clock) { OpenStruct.new(now: Time.at(1000)) }
  let(:session) { described_class.new(sinks: [->(l) { lines << l }], settings: settings, clock: -> { clock.now }) }
  let(:settings) { { 'on' => true } }

  before { session.install! }
  after { session.uninstall! }

  it 'writes the events of the categories that are on, and only those' do
    session.configure('on' => true, 'categories' => ['combat'])
    EO::Engine::Events.emit(:engaged, target: '1', name: 'kobold', routine: 'a')
    EO::Engine::Events.emit(:rest_started, reason: 'fried')
    expect(lines.size).to eq(1)
    expect(lines.first).to include('combat', 'engaged target=1')
  end

  it 'writes nothing while off, and starts again when turned on' do
    session.configure('on' => false)
    EO::Engine::Events.emit(:engaged, target: '1')
    expect(lines).to be_empty
    expect(session.configure('on' => true)).to be true
    expect(session.configure('on' => true)).to be false
    EO::Engine::Events.emit(:engaged, target: '1')
    expect(lines.size).to eq(1)
  end

  it 'carries the room from the last entered_room onto every line' do
    EO::Engine::Events.emit(:entered_room, room: 8030)
    EO::Engine::Events.emit(:engaged, target: '1')
    expect(lines.last).to include(' 8030   engaged')
  end

  it 'survives a sink that raises' do
    reached = []
    broken = described_class.new(sinks: [->(_l) { raise 'disk full' }, ->(l) { reached << l }], settings: settings)
    broken.install!
    expect { EO::Engine::Events.emit(:engaged, target: '1') }.not_to raise_error
    expect(reached.size).to eq(1)
    broken.uninstall!
  end

  it 'stops writing once uninstalled' do
    session.uninstall!
    EO::Engine::Events.emit(:engaged, target: '1')
    expect(lines).to be_empty
  end

  describe 'the tick line' do
    def behavior(name, priority, wants, reason: nil, result: nil)
      b = Class.new(EO::Engine::Behavior) do
        attr_reader :reason

        define_method(:name) { name }
        define_method(:priority) { priority }
        define_method(:wants_control?) { |_w| wants }
        define_method(:tick) { |_w| result }
      end.new
      b.instance_variable_set(:@reason, reason)
      b
    end

    let(:world) { OpenStruct.new(room: OpenStruct.new(id: 8030), me: OpenStruct.new(muckled?: false)) }
    let(:result) { EO::Engine::Actions::Result.new(status: :success, reason: :attacked) }
    let(:behaviors) do
      [behavior('survival', 0, false), behavior('rest', 20, false, reason: :not_fried),
       behavior('engage', 50, true, result: result), behavior('wander', 60, true)]
    end
    let(:engine) { EO::Engine::Engine.new(world: world, behaviors: behaviors, interval: 0) }

    it 'says who held the tick, what came of it, and why each behavior above declined' do
      session.configure('on' => true, 'tick' => true)
      session.install!(engine)
      engine.tick
      line = lines.find { |l| l.include?('tick #1') }
      expect(line).to include('engine   8030   tick #1 holder=engage status=success reason=attacked')
      expect(line).to include('| declined: survival=none rest=not_fried')
      expect(line).not_to include('wander')
    end

    it 'says why the holder wanted the tick and how long a slow turn took' do
      holder = behavior('survival', 0, true, reason: :prone, result: EO::Engine::Actions::Result.new(status: :success))
      slow = EO::Engine::Engine.new(world: world, behaviors: [holder], interval: 0)
      allow(slow).to receive(:last_action_seconds).and_return(20.8)
      session.configure('on' => true, 'tick' => true)
      session.install!(slow)
      slow.tick
      expect(lines.last).to include('holder=survival why=prone took=20.8s status=success')
    end

    it 'is off unless asked for, and marks an idle tick' do
      session.install!(engine)
      engine.tick
      expect(lines.grep(/tick #/)).to be_empty
      session.configure('on' => true, 'tick' => true)
      behaviors.each { |b| allow(b).to receive(:wants_control?).and_return(false) }
      engine.tick
      expect(lines.last).to include('tick #2 holder=idle status=-')
    end
  end
end
