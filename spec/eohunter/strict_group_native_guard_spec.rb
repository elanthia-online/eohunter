# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Actions::GroupMove, 'with the actual native Script guard' do
  before(:all) do
    root = ENV['LICH_EXECUTION_GUARD_ROOT']
    skip 'set LICH_EXECUTION_GUARD_ROOT for native Script guard integration' unless root

    require File.join(root, 'lib/common/script_execution_guard')
    source = File.read(File.join(root, 'lib/common/script.rb'))
    @owner_class = Class.new do
      def execution_guard_mutex = (@mutex ||= Mutex.new)
    end
    @owner_class.const_set(:ScriptExecutionGuard, Lich::Common::ScriptExecutionGuard)
    %w[with_execution_guard execution_guard_active? check_execution_guard!].each do |name|
      method_source = source[/^      def #{Regexp.escape(name)}(?:\(|\n).*?^      end$/m]
      raise "native Script method unavailable: #{name}" unless method_source

      @owner_class.class_eval(method_source, File.join(root, 'lib/common/script.rb'))
    end
  end

  let(:owner) { @owner_class.new }
  let(:me) { OpenStruct.new(dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false) }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 1, count: 1)) }
  let(:leader) { double('leader', movement_guard_scope: nil, consume_movement!: true) }
  let(:sent) { [] }
  let(:action) { described_class.new(world, leader: leader, way: 'north') }

  before do
    allow(Script).to receive(:current).and_return(owner)
    allow(action).to receive(:settle_rt)
  end

  def wire(command = "#{$cmd_prefix}north")
    owner.check_execution_guard!(command: command)
    sent << command
  end

  it 'consumes at the actual first wire check and disposes the native guard' do
    allow(action).to receive(:game_move) do
      expect(leader).not_to have_received(:consume_movement!)
      wire
      world.room.count += 1
      true
    end
    expect(action.call).to be_success
    expect(leader).to have_received(:consume_movement!).once
    expect(sent).to eq(["#{$cmd_prefix}north"])
    expect(owner.execution_guard_active?).to be false
  end

  it 'rechecks readiness after a delay inside native movement before the first wire' do
    allow(action).to receive(:game_move) do
      # Move marks its attempt before entering native move; a rejected first
      # wire must correct that provisional stamp using the guard observation.
      action.instance_variable_set(:@acted, true)
      allow(leader).to receive(:consume_movement!).and_return(false)
      wire
    end
    result = action.call
    expect(result).to be_skipped
    expect(result.reason).to eq(:movement_barrier)
    expect(result).not_to be_acted
    expect(sent).to be_empty
    expect(owner.execution_guard_active?).to be false
  end

  it 'rejects native movement retries after the first permitted send' do
    allow(action).to receive(:game_move) do
      wire
      wire
    end
    result = action.call
    expect(result).to be_failed
    expect(result).to be_acted
    expect(result.reason).to eq(:movement_barrier)
    expect(sent.size).to eq(1)
    expect(leader).to have_received(:consume_movement!).once
    expect(owner.execution_guard_active?).to be false
  end

  it 'rejects unrelated commands without consuming movement readiness' do
    allow(action).to receive(:game_move) { wire("#{$cmd_prefix}stand") }
    expect(action.call.reason).to eq(:movement_barrier)
    expect(sent).to be_empty
    expect(leader).not_to have_received(:consume_movement!)
  end

  it 'refuses nesting without a trusted composition adapter' do
    owner.with_execution_guard(->(_wire) { true }) do |outer|
      expect(action.call.reason).to eq(:unsupported_movement_guard)
      expect(outer.cancelled?).to be false
    end
    expect(leader).not_to have_received(:consume_movement!)
  end

  it 'fails closed when the native owner guard is unavailable' do
    allow(Script).to receive(:current).and_return(nil)
    expect(action).not_to receive(:game_move)
    expect(action.call.reason).to eq(:unsupported_movement_guard)
  end

  it 'propagates unrelated outer authority loss through a trusted adapter' do
    active_policy = nil
    scope = ->(policy, &work) { active_policy = policy; work.call }
    allow(leader).to receive(:movement_guard_scope).and_return(scope)
    allow(action).to receive(:game_move) { wire }
    outer_policy = ->(command) { command.nil? ? (active_policy ? active_policy.call(nil) : true) : false }
    expect do
      owner.with_execution_guard(outer_policy) { action.call }
    end.to raise_error(Lich::Common::ScriptExecutionGuard::Interrupted)
    expect(leader).not_to have_received(:consume_movement!)
    expect(sent).to be_empty
  end
end
