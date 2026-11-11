# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

AidSpell = Struct.new(:num, :known, :affordable, keyword_init: true) do
  def known? = known
  def affordable? = affordable
  def cast(*args) = (casts << args; 'Cast Roundtime 3 Seconds.')
  def casts = (@casts ||= [])
end unless defined?(AidSpell)

module AidSpecHelpers
  def pc(noun, status = '') = OpenStruct.new(noun: noun, name: noun, status: status)

  def entry(*helps, ailments: []) = { helps: helps, ailments: ailments }
end

RSpec.describe EO::Engine::Cleanse::Aid do
  include AidSpecHelpers

  let(:me) { OpenStruct.new(dead?: false, muckled?: false, able_to_cast?: true, poisoned?: false, diseased?: false, debuff_names: []) }
  let(:spells) { {} }
  let(:room) { OpenStruct.new(id: 1, players: []) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room, group_nouns: %w[Nisugi Zoleta Monstr Sugiin Dicate]) }
  let(:state) { EO::Engine::Cleanse::State.new }
  let(:t0) { Time.at(1000) }
  # The group from the 2026-11-10 death: three of the five know 108.
  let(:roster) do
    { 'Nisugi' => entry(108), 'Zoleta' => entry(108), 'Monstr' => entry(108, 114), 'Sugiin' => entry, 'Dicate' => entry(108) }
  end

  def know(*nums, affordable: true) = nums.each { |n| spells[n] = AidSpell.new(num: n, known: true, affordable: affordable) }

  def pick(name, at) = described_class.pick(world, roster, name, state, at)

  before do
    know(108)
    room.players = %w[Nisugi Zoleta Monstr Sugiin Dicate].map { |n| pc(n) }
  end

  context 'when a groupmate is stunned' do
    before { room.players.find { |p| p.noun == 'Dicate' }.status = 'stunned' }

    it 'has the first of the able, by name, cast 108 at once' do
      need = pick('Monstr', t0)
      expect([need.victim, need.kind, need.spell.num]).to eq(['Dicate', :stun, 108])
    end

    it 'has each next one wait its turn' do
      expect(pick('Nisugi', t0)).to be_nil
      expect(pick('Nisugi', t0 + 1.4)).to be_nil
      expect(pick('Nisugi', t0 + 1.5).victim).to eq('Dicate')
      state.aid_seen.clear
      expect(pick('Zoleta', t0)).to be_nil
      expect(pick('Zoleta', t0 + 2.9)).to be_nil
      expect(pick('Zoleta', t0 + 3.0).victim).to eq('Dicate')
    end

    it 'moves up a turn when one ahead is muckled itself' do
      room.players.find { |p| p.noun == 'Monstr' }.status = 'horrified'
      expect(pick('Nisugi', t0).victim).to eq('Dicate')
    end

    it 'skips a groupmate who knows no remedy, and the victim itself' do
      roster['Monstr'] = entry
      expect(pick('Nisugi', t0).victim).to eq('Dicate')
      expect(described_class.candidates(world, roster, 'Nisugi', [108], 'Dicate', :stun)).to eq(%w[Nisugi Zoleta])
    end

    it 'acts on its own knowledge when the roster has not arrived' do
      expect(described_class.pick(world, {}, 'Zoleta', state, t0).victim).to eq('Dicate')
    end

    it 'does not cast again until the repeat has passed' do
      state.aid_cast_at[['Dicate', :stun]] = t0
      expect(pick('Monstr', t0 + 1)).to be_nil
      expect(pick('Monstr', t0 + described_class::REPEAT[:stun]).victim).to eq('Dicate')
    end

    it 'does nothing while this character cannot cast, but still notes the need' do
      me[:muckled?] = true
      seen = []
      EO::Engine::Events.on(:aid_seen) { |e| seen << e.data }
      expect(pick('Monstr', t0)).to be_nil
      expect(seen).to eq([{ victim: 'Dicate', need: :stun }])
      expect(state.aid_seen).to have_key(['Dicate', :stun])
    end

    it 'casts nothing once the game says the stun is over, though the status lags' do
      state.aid_cleared['Dicate'] = t0
      expect(pick('Monstr', t0 + 0.2)).to be_nil
      expect(pick('Monstr', t0 + described_class::REPEAT[:stun]).victim).to eq('Dicate')
    end

    it 'reads the game line that ends a groupmate stun' do
      line = '<a exist="-10017918" noun="Monstr">Monstr</a> shakes off <a exist="-10017918" noun="Monstr">his</a> stunned state.'
      expect(described_class::CLEARED.match(line)[1]).to eq('Monstr')
    end

    it 'does nothing without an affordable remedy' do
      know(108, affordable: false)
      expect(pick('Monstr', t0)).to be_nil
    end

    it 'forgets a need once the room stops showing it, so a new stun starts fresh' do
      pick('Zoleta', t0)
      room.players.find { |p| p.noun == 'Dicate' }.status = ''
      pick('Zoleta', t0 + 1)
      expect(state.aid_seen).to be_empty
    end
  end

  it "sees a groupmate's stun from the roster when Lich's group does not know it" do
    world[:group_nouns] = ['Nisugi'] # a follower that joined last
    room.players.find { |p| p.noun == 'Dicate' }.status = 'stunned'
    expect(pick('Monstr', t0).victim).to eq('Dicate')
    expect(described_class.pick(world, {}, 'Monstr', EO::Engine::Cleanse::State.new, t0)).to be_nil
  end

  it 'ignores a stunned player outside the group, and a dead groupmate' do
    room.players << pc('Stranger', 'stunned')
    room.players.find { |p| p.noun == 'Dicate' }.status = 'dead'
    expect(pick('Monstr', t0)).to be_nil
  end

  it 'leaves a webbed groupmate to whoever knows 1040' do
    room.players.find { |p| p.noun == 'Dicate' }.status = 'webbed'
    expect(pick('Monstr', t0)).to be_nil
    roster['Zoleta'] = entry(1040)
    know(1040)
    expect(pick('Zoleta', t0).spell.num).to eq(1040)
  end

  # The rally the aid replaces covered Survival::STUNNED; every status
  # in it but stunned still reaches 1040 here.
  %w[immobilized horrified staggered].push('held in place').each do |status|
    it "rallies a groupmate who is #{status}" do
      room.players.find { |p| p.noun == 'Dicate' }.status = status
      roster['Zoleta'] = entry(1040)
      know(1040)
      expect(pick('Zoleta', t0).spell.num).to eq(1040)
    end
  end

  it 'prefers 108 for a stun when both are known' do
    know(1040)
    room.players.find { |p| p.noun == 'Dicate' }.status = 'stunned'
    expect(pick('Monstr', t0).spell.num).to eq(108)
  end

  context 'when a groupmate reports a poison' do
    before do
      know(114)
      roster['Dicate'] = entry(ailments: [:poison])
    end

    it 'cures one who cannot cure itself at once' do
      need = pick('Monstr', t0)
      expect([need.victim, need.kind, need.spell.num]).to eq(['Dicate', :poison, 114])
    end

    it 'gives one who can cure itself the first chance' do
      roster['Dicate'] = entry(114, ailments: [:poison])
      expect(pick('Monstr', t0)).to be_nil
      expect(pick('Monstr', t0 + described_class::SELF_GRACE).kind).to eq(:poison)
    end

    it 'ignores a report from a groupmate who is not here' do
      room.players.reject! { |p| p.noun == 'Dicate' }
      expect(pick('Monstr', t0)).to be_nil
    end
  end

  it 'publishes what this character can cast for others and what ails it unseen' do
    know(114)
    me[:poisoned?] = true
    expect(described_class.own(world)).to eq(helps: [108, 114], ailments: [:poison])
    me[:poisoned?] = false
    me[:debuff_names] = ['Wall of Thorns Poison']
    me[:diseased?] = true
    expect(described_class.own(world)).to eq(helps: [108, 114], ailments: %i[poison disease])
  end
end

RSpec.describe EO::Engine::Cleanse::Predicates do
  include AidSpecHelpers

  let(:me) do
    OpenStruct.new(wounds: {}, able_to_cast?: true, poisoned?: true, diseased?: false, stunned?: false, webbed?: false, bound?: false, hidden?: false,
                   stamina: 100, blessings_ranks: 0, debuff_names: [], dead?: false, muckled?: false, sleeping?: false)
  end
  let(:spells) { { 108 => AidSpell.new(num: 108, known: true, affordable: true), 114 => AidSpell.new(num: 114, known: true, affordable: true) } }
  let(:room) { OpenStruct.new(id: 1, loot: [], targets: [], players: [pc('Dicate', 'stunned')]) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room, group_nouns: ['Dicate']) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(cleanse_poison: true) }
  let(:state) { EO::Engine::Cleanse::State.new }
  let(:aid) { EO::Engine::Cleanse::Aid::Link.new(name: 'Nisugi', source: -> { { 'Dicate' => entry } }) }

  before do
    me.define_singleton_method(:frozen?) { false }
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
  end

  it "puts a stunned groupmate ahead of our own poison" do
    expect(described_class.reason(world, policy, state, aid: aid)).to eq(:aid)
    expect(state.aid_need.victim).to eq('Dicate')
    expect(described_class.reason(world, policy, state)).to eq(:poison) # alone, no aid
  end

  it "cures our own poison before a groupmate's, then helps them" do
    room.players = [pc('Dicate', nil)]
    poisoned = EO::Engine::Cleanse::Aid::Link.new(name: 'Nisugi', source: -> { { 'Dicate' => entry(ailments: [:poison]) } })
    expect(described_class.reason(world, policy, state, aid: poisoned)).to eq(:poison)
    me[:poisoned?] = false
    state.aid_seen.transform_values! { |at| at - 60 } # past the grace a self-curer gets
    expect(described_class.reason(world, policy, state, aid: poisoned)).to eq(:aid)
    expect(state.aid_need.kind).to eq(:poison)
  end

  it 'leaves the old one-cast 1040 rally to a character with group aid off' do
    spells[1040] = AidSpell.new(num: 1040, known: true, affordable: true)
    policy.troubadours_rally = true
    me[:poisoned?] = false
    expect(described_class.reason(world, policy, state)).to eq(:rally_member)
    expect(described_class.reason(world, policy, state, aid: aid)).to eq(:aid)
  end

  it 'reads a roster source that fails as empty' do
    broken = EO::Engine::Cleanse::Aid::Link.new(name: 'Nisugi', source: -> { raise 'DRb gone' })
    expect(broken.roster).to eq({})
  end
end

RSpec.describe EO::Engine::Actions::CleanseAid do
  include AidSpecHelpers

  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:room) { OpenStruct.new(id: 1, players: [pc('Dicate', 'stunned')]) }
  let(:world) { OpenStruct.new(me: me, room: room) }

  def aid(num, kind = :stun)
    spell = AidSpell.new(num: num, known: true, affordable: true)
    action = described_class.new(world, need: EO::Engine::Cleanse::Aid::Need.new(victim: 'Dicate', kind: kind, spell: spell))
    allow(action).to receive(:settle_rt)
    [action.call, spell]
  end

  it 'casts 108 at the groupmate' do
    result, spell = aid(108)
    expect(result.reason).to eq(:aid_stun)
    expect(spell.casts).to eq([['at Dicate']])
  end

  it 'sings 1040 to the room' do
    _, spell = aid(1040)
    expect(spell.casts).to eq([[]])
  end

  it 'casts nothing once the game said the stun ended' do
    spell = AidSpell.new(num: 108, known: true, affordable: true)
    action = described_class.new(world, need: EO::Engine::Cleanse::Aid::Need.new(victim: 'Dicate', kind: :stun, spell: spell), cleared: -> { true })
    allow(action).to receive(:settle_rt)
    expect(action.call.reason).to eq(:recovered)
    expect(spell.casts).to be_empty
  end

  it 'casts nothing once the groupmate is over it' do
    room.players.first.status = ''
    result, spell = aid(108)
    expect(result.reason).to eq(:recovered)
    expect(spell.casts).to be_empty
  end

  def poison_aid(roster)
    spell = AidSpell.new(num: 114, known: true, affordable: true)
    action = described_class.new(world, need: EO::Engine::Cleanse::Aid::Need.new(victim: 'Dicate', kind: :poison, spell: spell),
                                        roster: -> { roster })
    [action, spell]
  end

  it 'trusts a reported poison, which the room cannot show' do
    room.players.first.status = ''
    action, spell = poison_aid({ 'Dicate' => { ailments: [:poison] } })
    allow(action).to receive(:settle_rt)
    expect(action.call.reason).to eq(:aid_poison)
    expect(spell.casts).to eq([['at Dicate']])
  end

  it 'casts nothing when a newer report says another member cured the poison during our roundtime' do
    room.players.first.status = ''
    roster = { 'Dicate' => { ailments: [:poison] } }
    action, spell = poison_aid(roster)
    allow(action).to receive(:settle_rt) { roster['Dicate'] = { ailments: [] } }
    expect(action.call.reason).to eq(:recovered)
    expect(spell.casts).to be_empty
  end
end

RSpec.describe EO::Engine::Group::Leader do
  include AidSpecHelpers

  let(:hub) do
    h = EO::Engine::Group::Hub.new
    h.open_hunt(leader: 'Nisugi', expected: %w[Dicate Zoleta], rooms: {})
    %w[Dicate Zoleta].each { |n| h.register(n, hunt_id: h.hunt_id) }
    h.activate!
    h
  end
  let(:leader) { described_class.new(hub, name: 'Nisugi') }
  let(:world) { OpenStruct.new(room: OpenStruct.new(id: 1)) }

  def report(name, aid) = EO::Engine::Group::Report.new(name: name, room: 1, rt: false, aid: aid, at: Time.now)

  it "merges its own entry with each follower's into the state every follower gets back" do
    hub.report('Dicate', report('Dicate', entry(108, ailments: [:poison])))
    hub.report('Zoleta', report('Zoleta', nil))
    leader.publish(world, phase: :hunting, aid: entry(108, 114))
    expect(leader.aid_roster).to eq('Nisugi' => entry(108, 114), 'Dicate' => entry(108, ailments: [:poison]))

    member = EO::Engine::Group::Member.new(hub, name: 'Zoleta', deadline: 0.5)
    member.register
    member.report(report('Zoleta', entry))
    expect(member.aid_roster.keys).to contain_exactly('Nisugi', 'Dicate')
  end

  it 'publishes no roster with group aid off' do
    leader.publish(world, phase: :hunting)
    expect(leader.aid_roster).to eq({})
  end
end
