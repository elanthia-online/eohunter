# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Tracking do
  it 'reads bandit mode from the word or the bounty, and the quarry after track' do
    expect(described_class.policy_from([]).bandits?).to be false
    expect(described_class.policy_from(['bandits']).bandits?).to be true
    expect(described_class.policy_from([], task: OpenStruct.new(bandit?: true)).bandits?).to be true
    expect(described_class.policy_from([], task: OpenStruct.new(bandit?: false)).bandits?).to be false
    expect(described_class.policy_from([], task: nil).bandits?).to be false
    p = described_class.policy_from(%w[track giant rat])
    expect(p.creature_name).to eq('giant rat')
    expect(p.tracking?).to be true
    expect(described_class.policy_from(['track']).tracking?).to be false
  end

  it "tracks the profile's creature when its track setting is on, and the command line's over it" do
    profile = ->(raw) { EO::Engine::Profile.new(raw) }
    on = profile.call('track' => true, 'track_creature' => ' giant rat ')
    expect(described_class.policy_from([], profile: on).creature_name).to eq('giant rat')
    expect(described_class.policy_from(%w[track kobold], profile: on).creature_name).to eq('kobold')
    expect(described_class.policy_from(['track'], profile: on).creature_name).to eq('giant rat')
    expect(described_class.policy_from([], profile: profile.call('track' => false, 'track_creature' => 'giant rat')).tracking?).to be false
    expect(described_class.policy_from([], profile: profile.call('track' => true)).tracking?).to be false
    expect(described_class.policy_from([], profile: profile.call({})).tracking?).to be false
  end

  it 'hunts only the bandit nouns, on the quick routine, in bandit mode' do
    policy = EO::Engine::Targets::Policy.new(wanted: described_class.bandit_targets)
    roster = [OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', status: '', type: 'aggressive npc'),
              OpenStruct.new(id: '2', name: 'human brigand', noun: 'brigand', status: '', type: 'bandit'),
              OpenStruct.new(id: '3', name: 'elven highwayman', noun: 'highwayman', status: '', type: 'bandit')]
    expect(EO::Engine::Targets.candidates(roster, policy).map(&:id)).to eq(%w[2 3])
    expect(EO::Engine::Targets.routine_for(roster[1], policy)).to eq('quick')
  end

  # bigshot reaches set_bandit_hunting only from inside
  # `if options.any? { |var| var =~ /bounty/i }`, so a bandit task merely
  # held in the pack changes nothing on an ordinary hunt. The script used
  # to hand the live bounty to policy_from unconditionally, which swapped
  # an ordinary hunt's targets for the bandit nouns and stopped it fleeing.
  describe 'the script-level bandit gate' do
    let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }

    it 'passes the bounty task to policy_from only in bounty mode' do
      call = source[/tracking = EO::Engine::Tracking\.policy_from\(.*?\)\n/m]
      expect(call).to include('bounty_mode ? bounty_task : nil')
    end

    it 'still lets the bandits word stand on its own' do
      expect(described_class.policy_from(['bandits']).bandits?).to be true
      expect(described_class.policy_from(['bandits'], task: nil).bandits?).to be true
    end
  end
end

RSpec.describe EO::Engine::Actions::Track do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, profession: 'Ranger', able_to_search?: true) }
  let(:world) { OpenStruct.new(me: me, room: OpenStruct.new(id: 1, targets: [])) }
  let(:sent) { [] }

  before { me.define_singleton_method(:cooldown_active?) { |_n| false } }

  def track(reply, creature: 'giant rat')
    action = described_class.new(world, creature: creature)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_and_match) { |cmd, _rx, **| sent << cmd; EO::Engine::Actions::Result.new(status: :success, line: reply) }
    action
  end

  it 'follows a trail and reports a quarry hidden here as success' do
    expect(track('Your keen eye spots the beginnings of a trail and you rush to follow it.').call.reason).to eq(:trail)
    expect(track("You don't have to go far.").call.reason).to eq(:here)
    expect(sent).to eq(['track giant rat', 'track giant rat'])
  end

  it 'fails with the game\'s reason otherwise' do
    expect(track('A giant rat was here, but the trail is clearly too old to be worth following.').call.reason).to eq(:too_old)
    expect(track("You don't know how to track creatures within town.").call.reason).to eq(:town)
  end

  it 'refuses for a non-Ranger, on cooldown, or with no creature' do
    expect(track('x', creature: '').call.reason).to eq(:no_creature)
    me.profession = 'Warrior'
    expect(track('x').call.reason).to eq(:not_a_ranger)
    me.profession = 'Ranger'
    me.define_singleton_method(:cooldown_active?) { |n| n == 'Tracking' }
    expect(track('x').call.reason).to eq(:cooldown)
    expect(sent).to be_empty
  end
end

RSpec.describe EO::Engine::Actions::Uncover do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, profession: 'Ranger', able_to_search?: true) }
  let(:spells) { {} }
  let(:room) { OpenStruct.new(id: 1, targets: []) }
  let(:world) { OpenStruct.new(me: me, room: room, spell: spells) }
  let(:sent) { [] }

  def uncover
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'ok' }
    action
  end

  it 'searches, or casts 609 open for a Ranger who has it' do
    expect(uncover.call.reason).to eq(:searched)
    spells[609] = OpenStruct.new(known?: true, affordable?: true)
    expect(uncover.call.reason).to eq(:spell_609)
    expect(sent).to eq(['search', 'incant 609 open'])
  end

  it 'does nothing with something hostile already showing' do
    room.targets = [OpenStruct.new(id: '1')]
    expect(uncover.call.reason).to eq(:creatures_here)
    expect(sent).to be_empty
  end

  # The ladder answers a failed Result for :dead, :interrupted,
  # :too_many_resends and :no_response. Discarding it reported an uncover
  # that never happened, and the caller then treats the room as searched.
  it 'reports the ladder failure instead of a search that never happened' do
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_through_ladder) do |cmd|
      sent << cmd
      EO::Engine::Actions::Result.new(status: :failed, reason: :interrupted)
    end

    result = action.call
    expect(result).not_to be_success
    expect(result.reason).to eq(:interrupted)
  end

  it 'reports the failure on the 609 branch too' do
    spells[609] = OpenStruct.new(known?: true, affordable?: true)
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:send_through_ladder) do |cmd|
      sent << cmd
      EO::Engine::Actions::Result.new(status: :failed, reason: :dead)
    end

    expect(action.call.reason).to eq(:dead)
  end

  it "does not SEARCH when Lich's Injured says the head cannot, but still casts 609" do
    me[:able_to_search?] = false
    expect(uncover.call.reason).to eq(:too_injured)
    spells[609] = OpenStruct.new(known?: true, affordable?: true)
    expect(uncover.call.reason).to eq(:spell_609)
    expect(sent).to eq(['incant 609 open'])
  end
end
