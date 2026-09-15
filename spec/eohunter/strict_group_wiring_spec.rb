# frozen_string_literal: true

require 'ostruct'
require 'drb/drb'
require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'strict movement entrypoint wiring' do
  let(:adapter) do
    source = File.read(File.expand_path('../../scripts/eohunter.lic', __dir__))
    Module.new.tap { |mod| mod.module_eval(source[/^module EOHunter\n.*?\nend\n/m]) }::EOHunter
  end
  let(:owner) do
    Object.new.tap do |value|
      value.define_singleton_method(:with_execution_guard) { |*| }
      value.define_singleton_method(:execution_guard_active?) { false }
    end
  end
  let(:parser) { double('native parser', alive?: true) }
  let(:reader) { double('native reader', alive?: true) }
  let(:game) { OpenStruct.new(thread: parser, reader_thread: reader, closed?: false, remote_eof?: false) }
  let(:native_state) { { source: { connection_id: 'native', sequence: 1, received_at: 1.0 }, fields: {} }.freeze }

  before do
    stub_const('Game', game)
    stub_const('Char', OpenStruct.new(name: 'Testmage'))
    stub_const('XMLData', OpenStruct.new(game: 'TEST'))
    stub_const('EO::Coordination', Module.new) unless defined?(EO::Coordination)
    @projection = double('parser projection', install!: true, call: native_state, close: nil)
    projection_class = Class.new
    allow(projection_class).to receive(:new).and_return(@projection)
    stub_const('EO::Coordination::ParserProjection', projection_class)
    allow(EO::Coordination).to receive(:require_version).and_return(true)
    allow(Script).to receive(:loadlib)
    allow(Script).to receive(:current).and_return(owner)
    allow(Script).to receive(:list).and_return([owner])
  end

  it 'does not enable strict movement for existing profiles' do
    expect(EO::Engine::Profile.new({})['group_strict_movement']).to be false
    expect(EO::Engine::Profile.new({ 'group_strict_movement' => true })['group_strict_movement']).to be true
  end

  it 'pins live native workers and permanently invalidates a replaced connection' do
    identity = adapter.group_identity_reader
    first = identity.call
    expect(first).to include(game: 'TEST', character: 'Testmage', connection_generation: 1)
    expect(first).to be_frozen
    game.thread = double('replacement parser', alive?: true)
    expect(identity.call).to be_nil
    game.thread = parser
    expect(identity.call).to be_nil
  end

  it 'invalidates EOF and loss of the exact Script owner' do
    identity = adapter.group_identity_reader
    game[:remote_eof?] = true
    expect(identity.call).to be_nil
    game[:remote_eof?] = false
    another = adapter.group_identity_reader
    allow(Script).to receive(:list).and_return([Object.new])
    expect(another.call).to be_nil
  end

  it 'refuses admission without both live native workers' do
    game.reader_thread = nil
    expect { adapter.group_identity_reader }.to raise_error(ArgumentError, /native connection/)
  end

  it 'refuses strict admission when native per-send guards are unavailable' do
    allow(Script).to receive(:current).and_return(Object.new)
    expect { adapter.group_identity_reader }.to raise_error(ArgumentError, /per-send/)
  end

  it 'installs and reads the external parser projection' do
    reader = adapter.group_native_reader
    expect(reader).to equal(@projection)
    expect(reader.call).to equal(native_state)
  end

  it 'closes a parser projection whose installation fails' do
    allow(@projection).to receive(:install!).and_raise('hook unavailable')
    expect(@projection).to receive(:close)

    expect { adapter.group_native_reader }.to raise_error(RuntimeError, 'hook unavailable')
  end

  it 'rejects count-only and LAN strict leaders before sending group commands' do
    profile = EO::Engine::Profile.new({ 'group_strict_movement' => true })
    expect(EO::Engine::Actions::GroupOpen).not_to receive(:new)
    [[], ['1'], ['Peer', 'lan']].each do |args|
      expect { adapter.lead(profile, nil, args) }.to raise_error(ArgumentError, /explicit follower names/)
    end
  end

  it 'rejects a nonlocal strict follower before starting DRb' do
    expect(DRb).not_to receive(:start_service)
    expect { adapter.follow(['druby://192.0.2.1:1234'], strict_movement: true) }
      .to raise_error(ArgumentError, /loopback/)
  end

  it 'releases the projection and local service when strict leader construction fails' do
    profile = EO::Engine::Profile.new({ 'group_strict_movement' => true })
    world = FakeWorld.new
    hub = double('hub', open_hunt: true, ready?: true, activate!: true, members: ['Peer'])
    allow(EO::Engine::Actions::GroupOpen).to receive(:new).and_return(double(call: true))
    allow(EO::Engine::Group::Hub).to receive(:new).and_return(hub)
    allow(DRb).to receive(:start_service)
    allow(DRb).to receive(:uri).and_return('druby://127.0.0.1:1234')
    allow(EO::Engine::Group::Leader).to receive(:new).and_raise('leader unavailable')
    expect(@projection).to receive(:close)
    expect(DRb).to receive(:stop_service)

    expect { adapter.lead(profile, world, ['Peer']) }.to raise_error(RuntimeError, 'leader unavailable')
  end

  it 'releases the projection and local service when strict follower construction fails' do
    allow(DRb).to receive(:start_service)
    allow(DRbObject).to receive(:new_with_uri).and_return(double('hub'))
    allow(EO::Engine::Group::Member).to receive(:new).and_raise('member unavailable')
    expect(@projection).to receive(:close)
    expect(DRb).to receive(:stop_service)

    expect { adapter.follow(['druby://127.0.0.1:1234'], strict_movement: true) }
      .to raise_error(RuntimeError, 'member unavailable')
  end

  it 'captures locally at completion and publishes only on the next start hook' do
    engine = EO::Engine::Engine.new(world: FakeWorld.new, behaviors: [])
    orders = double('orders')
    adapter.wire_movement(engine, orders: orders)
    expect(orders).to receive(:publish_movement).ordered
    expect(orders).to receive(:complete_owner_tick).with(anything, 1, hash_including(state: :running)).ordered
    expect(orders).to receive(:publish_movement).ordered
    expect(orders).to receive(:complete_owner_tick).with(anything, 2, hash_including(state: :running)).ordered
    engine.tick
    engine.tick
  end
end
