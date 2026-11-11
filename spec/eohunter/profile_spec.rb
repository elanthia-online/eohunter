# frozen_string_literal: true

require 'ostruct'
require 'tmpdir'
require 'yaml'
require_relative 'engine_helper'

RSpec.describe EO::Engine::Profile do
  let(:raw) do
    {
      'resting_room_id' => '29877', 'resting_commands' => 'store all', 'fried' => '101', 'overkill' => '2', 'oom' => '',
      'encumbered' => '20', 'wounded_eval' => 'hp < 60', 'hunting_room_id' => 'u7000', 'hunting_boundaries' => '29900, 30115',
      'rest_till_exp' => '100', 'rest_till_mana' => '90', 'hunting_stance' => 'Offensive', 'wander_stance' => 'Defensive',
      'hunting_prep_commands' => 'ready weapon, incant 515', 'signs' => '515, 506, 605', 'loot_script' => 'eloot',
      'delay_loot' => true, 'sneaky_sneaky' => true, 'loot_stance' => true, 'pull' => false, 'flee_count' => '100',
      'wander_wait' => 0.3, 'bless' => false,
      'hunting_right_hand' => 'READY:Weapon', 'hunting_left_hand' => 'empty',
      'hunting_commands' => 'kweed(buff5), script volley, coupdegrace(thp20 empowered30), incant 608(!hidden), hide(!hidden), fire(hidden)',
      'hunting_commands_e' => 'attack(x2), stance offensive and attack',
      'targets' => 'mastodon(b), berserker(d), shield-maiden(e), skald(c), warg(a), (?:.+?)(d)',
      'quickhunt_targets' => '', 'mstrike_mob' => '', 'ignore_disks' => false, 'depart_switch' => true, 'boons_flee' => [],
      'flee_message' => 'Danger Approaches'
    }
  end

  it 'reads the flee message as a case-insensitive pattern, nil when blank' do
    expect(profile['flee_message']).to match('You hear that danger approaches from the north.')
    expect(profile.flee_policy.message).to be_a(Regexp)
    expect(described_class.new({ 'flee_message' => '' })['flee_message']).to be_nil
  end
  let(:profile) { described_class.new(raw, name: 'ojandhaart', uid_ids: ->(uid) { uid == 7000 ? [29902] : [] }) }

  it 'reads numbers, blanks, booleans and stances the way clean_value does' do
    expect(profile['fried']).to eq(101)
    expect(profile['oom']).to eq(0)
    expect(profile['mstrike_mob']).to eq(2)
    expect(profile['delay_loot']).to be true
    expect(profile['pull']).to be false
    expect(profile['hunting_stance']).to eq('offensive')
    expect(profile['wander_wait']).to eq(0.3)
  end

  it 'resolves rooms, uids and boundary lists' do
    expect(profile['resting_room_id']).to eq(29877)
    expect(profile['hunting_room_id']).to eq(29902)
    expect(profile['hunting_boundaries']).to eq([29900, 30115])
  end

  it 'splits command lists with repeats and ands' do
    expect(profile['hunting_prep_commands']).to eq(['ready weapon', 'incant 515'])
    expect(profile['hunting_commands'].size).to eq(6)
    expect(profile['hunting_commands'].first).to eq('kweed(buff5)')
    expect(profile['hunting_commands_e']).to eq(['attack', 'attack', ['stance offensive', 'attack']])
  end

  it 'reads the targets list with letters and a default' do
    expect(profile['targets']).to eq('mastodon' => 'b', 'berserker' => 'd', 'shield-maiden' => 'e', 'skald' => 'c', 'warg' => 'a', '(?:.+?)' => 'd')
    expect(described_class.new({ 'targets' => 'kobold, orc(b)' })['targets']).to eq('kobold' => 'a', 'orc' => 'b')
  end

  it 'builds the policies' do
    hp = 50
    rest = profile.rest_policy(wounded_binding: binding)
    expect(rest.fried_pct).to eq(101)
    expect(rest.resting_room).to eq(29877)
    expect(rest.wounded.call).to be true
    expect(profile.targets_policy.matchers.map(&:last)).to eq(%w[b d e c a d])
    expect(profile.wander_policy.sneaky).to be true
    expect(profile.wander_policy.boundary_ids).to eq([29900, 30115])
    expect(profile.loot_policy.script).to eq('eloot')
    expect(profile.maintain_policy.signs).to eq(%w[515 506 605])
    expect(profile.survival_policy.on_death).to eq(:depart)
    expect(profile.engage_policy.routine_for('a').size).to eq(6)
    expect(profile.engage_policy.routine_for('c').size).to eq(6) # empty letters fall back to a
    expect(profile.engage_policy.hunting_stance).to eq('offensive')
    expect(profile.flee_policy.count).to eq(100)
    expect(profile.loadout_policy.right).to have_attributes(kind: :ready, value: :weapon)
    expect(profile.loadout_policy.left).to have_attributes(kind: :empty, value: nil)
  end

  it 'leaves both hands unmanaged for old and blank profiles' do
    old = described_class.new({})
    blank = described_class.new({ 'hunting_right_hand' => '', 'hunting_left_hand' => 'KEEP' })

    expect(old.loadout_policy).not_to be_managed
    expect(blank.loadout_policy).not_to be_managed
  end

  it 'builds named loadout selection without changing the baseline policy' do
    raw['hunting_loadout_sets'] = { 'silver' => { 'right' => 'silver blade' } }
    raw['hunting_loadout_rules'] = [{ 'set' => 'silver', 'target' => 'kobold' }]
    target = OpenStruct.new(id: '1', name: 'kobold', noun: 'kobold', type: 'aggressive npc')

    expect(profile.loadout_selection.select(target: target, world: nil).stash_arguments).to eq(right: 'silver blade', left: nil)
    expect(profile.loadout_policy.stash_arguments).to eq(right: :weapon, left: nil)
    expect(described_class.new({}).loadout_selection).not_to be_managed
  end

  it 'rejects malformed selection configuration during profile construction' do
    expect { described_class.new({ 'hunting_loadout_sets' => [] }) }.to raise_error(ArgumentError, /hunting_loadout_sets/)
    expect { described_class.new({ 'hunting_loadout_rules' => [{ 'set' => 'missing', 'type' => 'undead' }] }) }
      .to raise_error(ArgumentError, /hunting_loadout_rules/)
    expect { described_class.new({ 'hunting_right_hand' => 'ready:' }) }.to raise_error(ArgumentError, /ready/)
  end

  # Lich's Stance.normalize RAISES on a word it does not know, a string
  # under three characters, or a percentage that is not a multiple of ten
  # - and the stance lambdas call it on every hunting, wander, stand and
  # flee transition. A typo used to kill the engine mid-hunt.
  describe 'stance keys' do
    def stance_of(value) = described_class.new({ 'hunting_stance' => value })['hunting_stance']

    it 'keeps every form Lich can parse' do
      expect(stance_of('defensive')).to eq('defensive')
      expect(stance_of('DEFENSIVE')).to eq('defensive')
      expect(stance_of(' guarded ')).to eq('guarded')
      expect(stance_of('off')).to eq('off')          # a three-letter prefix is enough
      expect(stance_of('70')).to eq('70')            # a band percentage
      expect(stance_of('0')).to eq('0')
    end

    it 'falls back to the documented default on anything Lich would raise on' do
      expect(stance_of('aggressive')).to eq('defensive') # no such stance
      expect(stance_of('de')).to eq('defensive')         # under three characters
      expect(stance_of('55')).to eq('defensive')         # not a multiple of ten
      expect(stance_of('101')).to eq('defensive')        # out of range
      expect(stance_of('xyz')).to eq('defensive')
    end
  end

  # RULES.freeze is shallow, so the [], {} and ['any'] defaults are one
  # object shared by every Profile in the process. A Policy that appends
  # to what it takes for its own list edits the default itself, and the
  # next Profile - the bounty swap, a reload - inherits it.
  it 'does not share a mutable default between profiles' do
    first = described_class.new({})
    first['aim'] << 'head'
    expect(described_class.new({})['aim']).to be_empty
  end

  # A malformed flee_message used to kill the script at load with a raw
  # RegexpError out of the parser.
  describe 'an unusable pattern' do
    it 'is reported and left unset rather than raising' do
      profile = nil
      expect { profile = described_class.new({ 'flee_message' => 'flee [unclosed' }) }.not_to raise_error
      expect(profile['flee_message']).to be_nil
    end

    it 'still compiles a good one' do
      expect(described_class.new({ 'flee_message' => 'run away' })['flee_message']).to eq(/run away/i)
    end
  end
end

RSpec.describe EO::Engine::Profile, '#recovery_policy' do
  it 'is everything off but troubadours_rally when the hunt says nothing' do
    policy = described_class.new({ 'troubadours_rally' => true }).recovery_policy
    expect(policy.cleanse_poison).to be(false)
    expect(policy.safe_room).to eq('')
    expect(policy.troubadours_rally).to be(true)
  end

  it 'takes the hunt\'s own preferences' do
    policy = described_class.new({ 'recovery' => { 'cleanse_poison' => false, 'dispel_magic' => true, 'safe_room' => '228' } }).recovery_policy
    expect(policy.cleanse_poison).to be(false)
    expect(policy.dispel_magic).to be(true)
    expect(policy.safe_room).to eq('228')
  end

  it "carries the profile's stand_stance, so Cleanse stands as Survival does" do
    policy = described_class.new({ 'stand_stance' => 'guarded' }).recovery_policy
    expect(policy.stand_stance).to eq('guarded')
  end

  it 'lets the hunt override troubadours_rally too' do
    profile = described_class.new({ 'troubadours_rally' => true, 'recovery' => { 'troubadours_rally' => false } })
    expect(profile.recovery_policy.troubadours_rally).to be(false)
  end

  it 'keeps only Cleanse keys, and refuses a recovery that is not a mapping' do
    expect(described_class.new({ 'recovery' => { 'cleanse_poison' => false, 'nonsense' => 1 } }).recovery)
      .to eq(cleanse_poison: false)
    expect { described_class.new({ 'recovery' => 'yes' }) }.to raise_error(ArgumentError, /recovery/)
  end
end
