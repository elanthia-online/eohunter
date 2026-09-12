# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Preparations do
  let(:entry) { { 'perform' => 'feed my crystal', 'result' => 'user_feed_result', 'match' => { 'item' => 'crystal' }, 'expect' => { 'ok' => true }, 'timeout' => 0.01 } }

  def profile(definition, extra = {})
    EO::Engine::Profile.new({ 'resting_room_id' => 2, 'preparations' => definition }.merge(extra))
  end

  it 'shares validated definitions between routine and resting policies' do
    configured = profile({ 'crystal' => entry }, 'hunting_commands' => 'prepare crystal(once)', 'resting_commands' => 'prepare crystal')
    expect(configured.rest_policy.preparations).to equal(configured.engage_policy.preparations)
    expect(configured.preparations['crystal'].result).to eq(:user_feed_result)
    expect(EO::Engine::Profile.new({}).preparations).to be_empty
  end

  it 'rejects unknown names and malformed words before hunting' do
    %w[hunting_commands hunting_commands_b quick_commands disable_commands hunting_prep_commands resting_commands field_rest_commands field_hunting_prep_commands custom_fog].each do |key|
      expect { profile({ 'crystal' => entry }, key => 'prepare missing') }.to raise_error(ArgumentError, /unknown preparation missing/)
    end
    ['prepare', 'prepare crystal extra', 'prepare bad-name'].each do |word|
      expect { profile({ 'crystal' => entry }, 'hunting_commands' => word) }.to raise_error(ArgumentError, /invalid preparation word/)
    end
    expect { profile({ 'crystal' => entry }, 'resting_commands' => 'prepare crystal(once)') }.to raise_error(ArgumentError)
    ['force prepare crystal till 100', 'eachtarget prepare crystal', '506 prepare crystal'].each do |word|
      expect { profile({ 'crystal' => entry }, 'hunting_commands' => word) }.to raise_error(ArgumentError, /prefixes/)
    end
  end

  it 'requires a refuge and rejects coordination without a safe failure protocol' do
    expect { EO::Engine::Profile.new({ 'preparations' => { 'crystal' => entry } }) }.to raise_error(ArgumentError, /resting_room_id/)
    configured = profile('crystal' => entry)
    expect(configured.validate_rest_mode!(nil)).to be(true)
    %w[head tail].each { |mode| expect { configured.validate_rest_mode!(mode) }.to raise_error(ArgumentError, /solo/) }
    expect { configured.validate_rest_mode!(nil, bounty: true) }.to raise_error(ArgumentError, /solo/)
    expect { configured.validate_rest_mode!(nil, controlled: true) }.to raise_error(ArgumentError, /solo/)
  end

  it 'rejects named preparations nested in prep/rest arrays with a usable alternative' do
    %w[hunting_prep_commands resting_commands field_rest_commands field_hunting_prep_commands custom_fog].each do |key|
      expect { profile({ 'crystal' => entry }, key => 'look and prepare crystal') }.to raise_error(ArgumentError, /comma-separated prepare NAME/)
      expect { profile({ 'crystal' => entry }, key => 'prepare crystal, look') }.not_to raise_error
    end
    expect { profile({ 'crystal' => entry }, 'hunting_commands' => 'prepare crystal and attack') }.not_to raise_error
  end

  it 'rejects invalid structures, identifiers, fields and commands at profile load' do
    [nil, [], '', false].each { |raw| expect { profile(raw) }.to raise_error(ArgumentError, /preparations/) }
    [nil, [], 'bad'].each { |raw| expect { profile('crystal' => raw) }.to raise_error(ArgumentError, /crystal/) }
    ['UPPER', 'bad name', 123].each { |name| expect { profile(name => entry) }.to raise_error(ArgumentError) }
    [nil, '', "feed\nquit", 'feed;quit', ['feed'], "feed\rquit"].each do |command|
      expect { profile('crystal' => entry.merge('perform' => command)) }.to raise_error(ArgumentError, /crystal.*perform/)
    end
    [nil, 'bad result', 123].each do |name|
      expect { profile('crystal' => entry.merge('result' => name)) }.to raise_error(ArgumentError, /crystal.*result/)
    end
    expect { profile('crystal' => entry.merge('unknown' => true)) }.to raise_error(ArgumentError, /crystal.*unknown/)
    expect { profile('crystal' => entry.merge(:perform => 'feed')) }.to raise_error(ArgumentError, /duplicate/)
  end

  it 'accepts only finite positive numeric timeouts up to thirty seconds' do
    [0, -1, 31, Float::NAN, Float::INFINITY, nil, '6', true].each do |timeout|
      expect { profile('crystal' => entry.merge('timeout' => timeout)) }.to raise_error(ArgumentError, /crystal.*timeout/)
    end
    expect(profile('crystal' => entry.merge('timeout' => 30)).preparations['crystal'].timeout).to eq(30)
  end

  it 'accepts only flat scalar matching fields' do
    %w[match expect].each do |field|
      [nil, [], 'ok', { 'item' => [] }, { 'item' => {} }, { 'item' => Float::NAN }].each do |value|
        expect { profile('crystal' => entry.merge(field => value)) }.to raise_error(ArgumentError, /crystal/)
      end
    end
  end

  it 'matches exact scalar values and distinguishes missing keys from null' do
    expect(described_class.matches?({}, { ok: nil })).to be(false)
    expect(described_class.matches?({ 'ok' => nil }, { ok: nil })).to be(true)
    expect(described_class.matches?({ ok: 'true' }, { ok: true })).to be(false)
    expect(described_class.matches?({ count: 1.0 }, { count: 1 })).to be(false)
  end
end

RSpec.describe EO::Engine::Actions::Prepare do
  let(:world) { OpenStruct.new(me: OpenStruct.new(dead?: false, muckled?: false), message_events: [:user_feed_result]) }
  let(:definition) { { 'perform' => 'feed my crystal', 'result' => 'user_feed_result', 'match' => { 'item' => 'crystal' }, 'expect' => { 'ok' => true }, 'timeout' => 0.01 } }
  let(:preparations) { EO::Engine::Preparations.new('crystal' => definition) }
  let(:action) { described_class.new(world, name: 'crystal', preparations: preparations) }

  before { EO::Engine::Events.reset! }
  after { EO::Engine::Events.reset! }

  it 'arms before sending, ignores unrelated results and preserves the confirming event and acted stamp' do
    expect(action).to receive(:game_send).with('feed my crystal') do
      EO::Engine::Events.emit(:user_feed_result, item: 'other', ok: false)
      EO::Engine::Events.emit(:user_feed_result, item: 'crystal', ok: true)
      'fed'
    end
    result = action.call
    expect(result).to have_attributes(status: :success, reason: :prepared, acted: true)
    expect(result.event.data).to eq(item: 'crystal', ok: true)
  end

  it 'returns a correlated negative response as denial, without retrying' do
    expect(action).to receive(:game_send).once do
      EO::Engine::Events.emit(:user_feed_result, item: 'crystal', ok: false)
      'denied'
    end
    result = action.call
    expect(result).to have_attributes(status: :failed, reason: :denied, acted: true)
    expect(result.event.data[:ok]).to be(false)
  end

  it 'treats silence and unrelated replies as unconfirmed, not denial' do
    expect(action).to receive(:game_send).once do
      EO::Engine::Events.emit(:user_feed_result, item: 'other', ok: true)
      'sent'
    end
    expect(action.call).to have_attributes(status: :timeout, reason: :no_confirmation, event: nil, acted: true)
  end

  it 'rechecks runtime definition availability immediately before sending' do
    allow(action).to receive(:game_wait_rt) { world.message_events = [] }
    expect(action).not_to receive(:game_send)
    expect(action.call).to have_attributes(status: :failed, reason: :unknown_event)
  end

  it 'fails an unknown preparation without sending' do
    missing = described_class.new(world, name: 'missing', preparations: preparations)
    expect(missing).not_to receive(:game_send)
    expect(missing.call).to have_attributes(status: :failed, reason: :unknown_preparation)
  end

  it 'keeps ordinary unsent gates skipped without starting failure recovery' do
    world.me[:muckled?] = true
    expect(EO::Engine::Events).not_to receive(:emit).with(:preparation_failed, any_args)
    expect(action).not_to receive(:game_send)
    expect(action.call).to have_attributes(status: :skipped, reason: :muckled)
  end
end

RSpec.describe 'preparation routing and failure recovery' do
  let(:definition) { { 'perform' => 'feed my crystal', 'result' => 'user_feed_result', 'expect' => { 'ok' => true }, 'timeout' => 0.01 } }
  let(:profile) { EO::Engine::Profile.new({ 'resting_room_id' => 2, 'preparations' => { 'crystal' => definition }, 'hunting_prep_commands' => 'prepare crystal, attack' }) }
  let(:world) { OpenStruct.new(me: OpenStruct.new(dead?: false, muckled?: false), room: OpenStruct.new(id: 2), message_events: [:user_feed_result]) }
  let(:rest) { EO::Engine::Behaviors::Rest.new(policy: profile.rest_policy) }

  before { EO::Engine::Events.reset! }
  after { EO::Engine::Events.reset! }

  it 'uses the same action from a routine and a preparation list' do
    action = instance_double(EO::Engine::Actions::Prepare, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Prepare).to receive(:new).with(world, name: 'crystal', preparations: profile.preparations).twice.and_return(action)
    state = EO::Engine::Engage::State.new
    engage = OpenStruct.new(target: nil, policy: profile.engage_policy, state: state)
    line = EO::Engine::Engage::Routine.parse(['prepare crystal(once)']).first
    EO::Engine::Engage::Routines.run(engage, world, line.text, line)
    rest.send(:step_prep, world, ['prepare crystal'], [], :rally_out)
  end

  it 'preserves numeric game PREPARE commands in old profiles and both dispatch paths' do
    old = EO::Engine::Profile.new({ 'hunting_prep_commands' => 'prepare 101', 'hunting_commands' => 'prepare 101' })
    action = instance_double(EO::Engine::Actions::Command, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Command).to receive(:new).with(world, command: 'prepare 101').twice.and_return(action)
    rest.send(:step_prep, world, old.rest_policy.hunting_prep_commands, [], :rally_out)
    line = EO::Engine::Engage::Routine.parse(old.engage_policy.routine_for('a')).first
    engage = OpenStruct.new(target: nil, policy: old.engage_policy, state: EO::Engine::Engage::State.new)
    EO::Engine::Engage::Routines.run(engage, world, line.text, line)
  end

  it 'preserves game PREPARE by spell name when named preparations are disabled' do
    old = EO::Engine::Profile.new({ 'resting_commands' => 'prepare spirit warding i', 'hunting_commands' => 'prepare spirit warding i' })
    legacy_rest = EO::Engine::Behaviors::Rest.new(policy: old.rest_policy)
    action = instance_double(EO::Engine::Actions::Command, call: EO::Engine::Actions::Result.new(status: :success))
    expect(EO::Engine::Actions::Command).to receive(:new).with(world, command: 'prepare spirit warding i').twice.and_return(action)
    legacy_rest.send(:step_prep, world, old.rest_policy.resting_commands, [], :resting)
    line = EO::Engine::Engage::Routine.parse(old.engage_policy.routine_for('a')).first
    engage = OpenStruct.new(target: nil, policy: old.engage_policy, state: EO::Engine::Engage::State.new)
    EO::Engine::Engage::Routines.run(engage, world, line.text, line)
  end

  it 'blocks a failed prep at refuge and never sends the next command or repeats the consumed one' do
    allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:game_send) do
      EO::Engine::Events.emit(:user_feed_result, ok: false)
      'denied'
    end
    result = rest.send(:step_prep, world, profile.rest_policy.hunting_prep_commands, [], :rally_out)
    expect(result).to have_attributes(status: :failed, reason: :denied, acted: true)
    expect(rest.phase).to eq(:service_failed)
    expect(EO::Engine::Actions::Prepare).not_to receive(:new)
    expect(EO::Engine::Actions::Command).not_to receive(:new)
    3.times { expect(rest.tick(world)).to be_nil }
  end

  it 'returns through the existing lifecycle after a failure away from refuge and skips further preparations' do
    world.room.id = 1
    allow_any_instance_of(EO::Engine::Actions::Prepare).to receive(:game_send).and_return('sent')
    result = rest.send(:step_prep, world, ['prepare crystal'], [], :rally_out)
    expect(result.status).to eq(:timeout)
    expect(rest.phase).to eq(:leave)
    expect(rest.rest_site).to eq(:town)
    expect(EO::Engine::Actions::Prepare).not_to receive(:new)
    expect(rest.send(:step_prep, world, ['prepare crystal'], [], :resting).reason).to eq(:preparation_aborted)
  end

  it 'retries only unsent skipped preparations, keeping the next command pending' do
    world.me[:muckled?] = true
    expect(rest.send(:step_prep, world, ['prepare crystal', 'attack'], [], :rally_out)).to be_skipped
    world.me[:muckled?] = false
    expect_any_instance_of(EO::Engine::Actions::Prepare).to receive(:game_send).with('feed my crystal') do
      EO::Engine::Events.emit(:user_feed_result, ok: true)
      'fed'
    end
    expect(rest.send(:step_prep, world, [], [], :rally_out)).to be_success
  end
end
