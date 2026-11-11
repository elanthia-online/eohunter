# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

CleanseSpell = Struct.new(:num, :known, :affordable, :active, keyword_init: true) do
  def known? = known
  def affordable? = affordable
  def active? = active
  def available? = known && affordable
  def cast(*_a) = (@casts = (@casts || 0) + 1; 'Cast Roundtime 3 Seconds.')
  def force_incant(*_a) = cast
  def casts = @casts || 0
end unless defined?(CleanseSpell)

RSpec.describe EO::Engine::Actions::CleanseGrounded do
  it 'stands in the stand stance, not whatever stance it was in' do
    world = OpenStruct.new(me: OpenStruct.new(standing?: false, dead?: false))
    stand = instance_double(EO::Engine::Actions::Stand, call: nil)
    allow(EO::Engine::Actions::Stand).to receive(:new).and_return(stand)
    described_class.new(world, stand_stance: 'guarded').send(:stand_up, 'guarded')
    expect(EO::Engine::Actions::Stand).to have_received(:new).with(world, hash_including(stand_stance: 'guarded'))
  end
end

RSpec.describe EO::Engine::Cleanse::Casting do
  let(:me) { OpenStruct.new(able_to_cast?: true) }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:policy) { EO::Engine::Cleanse::Policy.new }

  it "answers with Lich's Injured.able_to_cast? through the facade" do
    expect(described_class.able?(world, policy)).to be true
    me[:able_to_cast?] = false
    expect(described_class.able?(world, policy)).to be false
  end

  it 'does not pre-approve a cast on a Sigil of Determination that is not up' do
    policy.determination = true
    spells['Sigil of Determination'] = CleanseSpell.new(num: 0, known: true, affordable: true, active: false)
    me[:able_to_cast?] = false
    expect(described_class.able?(world, policy)).to be false
    expect(described_class.determination?(world, policy)).to be true
  end

  it 'offers the sigil only when the policy allows and it is known and affordable' do
    expect(described_class.determination?(world, policy)).to be_falsey
    policy.determination = true
    expect(described_class.determination?(world, policy)).to be_falsey
    spells['Sigil of Determination'] = CleanseSpell.new(num: 0, known: true, affordable: false, active: false)
    expect(described_class.determination?(world, policy)).to be_falsey
    spells['Sigil of Determination'] = CleanseSpell.new(num: 0, known: true, affordable: true, active: false)
    expect(described_class.determination?(world, policy)).to be true
  end
end

RSpec.describe EO::Engine::Cleanse::Predicates do
  let(:me) do
    OpenStruct.new(wounds: {}, able_to_cast?: true, poisoned?: false, diseased?: false, stunned?: false, webbed?: false, bound?: false, hidden?: false,
                   stamina: 100, blessings_ranks: 0, debuff_names: [])
  end
  let(:spells) { {} }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', loot: [], targets: [], players: []) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room, group_nouns: []) }
  let(:policy) { EO::Engine::Cleanse::Policy.new }
  let(:state) { EO::Engine::Cleanse::State.new }

  before do
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    allow(described_class).to receive(:cman_known?).and_return(false)
    allow(described_class).to receive(:cman_available?).and_return(false)
    allow(described_class).to receive(:feat_available?).and_return(false)
  end

  def spell(num, **o) = spells[num] = CleanseSpell.new(num: num, known: true, affordable: true, active: false, **o)

  def reason = described_class.reason(world, policy, state)

  it "judges the sigil's wounds from Lich's Wounds ranks on the parts it covers" do
    me.wounds = { 'leftLeg' => 3 }
    expect(described_class.injured_for_sigil?(world)).to be(false)
    me.wounds = { 'rightArm' => 1, 'head' => 2 }
    expect(described_class.injured_for_sigil?(world)).to be(true)
  end

  it 'is nil when nothing is wrong or nothing is enabled' do
    expect(reason).to be_nil
    me[:poisoned?] = true
    expect(reason).to be_nil
    policy.cleanse_poison = true
    expect(reason).to be_nil # no 114
    spell(114)
    expect(reason).to eq(:poison)
  end

  it "rallies with 1040 first when Troubadour's Rally is on and we are incapacitated" do
    me[:sleeping?] = true
    me.define_singleton_method(:frozen?) { false }
    expect(reason).to be_nil
    policy.troubadours_rally = true
    expect(reason).to be_nil # no 1040
    spell(1040)
    expect(reason).to eq(:rally)
    me[:sleeping?] = false
    me[:stunned?] = true
    policy.use_stunned1040 = true
    expect(reason).to eq(:rally) # before the stun means
    me[:stunned?] = false
    expect(reason).to be_nil
  end

  it 'rallies once for a stunned group member here, then not again for a while' do
    policy.troubadours_rally = true
    spell(1040)
    me.define_singleton_method(:frozen?) { false }
    room.players = [OpenStruct.new(noun: 'Bob', status: 'stunned')]
    expect(reason).to be_nil # not in our group
    world[:group_nouns] = ['Bob']
    expect(reason).to eq(:rally_member)
    state.rally_member_at = Time.now
    expect(reason).to be_nil
  end

  it 'puts queued line events first, then the afflictions in ecleanse order' do
    policy.cleanse_poison = policy.cleanse_disease = true
    spell(114); spell(113)
    me[:poisoned?] = me[:diseased?] = true
    expect(reason).to eq(:poison)
    me[:poisoned?] = false
    expect(reason).to eq(:disease)
    state.enqueue(event: :use_vat)
    expect(reason).to eq(:queued)
  end

  it 'only claims a stun it has a means for' do
    me[:stunned?] = true
    expect(reason).to be_nil
    policy.use_stunned1040 = true
    spell(1040)
    expect(reason).to eq(:stun)
    spells.clear
    policy.use_flee = true
    allow(described_class).to receive(:cman_available?).with('Stun Maneuvers', min_rank: 5).and_return(true)
    expect(reason).to eq(:stun)
    room.title = '[The Belly of the Beast]'
    expect(reason).to be_nil
  end

  it 'finds the hazards on the floor, skipping bad targets, gems and the invalid clouds' do
    policy.dispel_magic = policy.avoid_webs = policy.break_runestone = true
    spell(417); spell(209)
    room.loot = [OpenStruct.new(id: '1', name: 'cloud of thick ethereal fog', noun: 'fog', type: ''),
                 OpenStruct.new(id: '2', name: 'a cloud agate', noun: 'agate', type: 'gem'),
                 OpenStruct.new(id: '3', name: 'a noxious cloud', noun: 'cloud', type: '')]
    expect(reason).to eq(:cloud)
    state.bad_target!('3')
    expect(reason).to be_nil
    room.loot << OpenStruct.new(id: '4', name: 'a silvery blue globe', noun: 'globe', type: '')
    expect(reason).to eq(:globe)
    room.loot = [OpenStruct.new(id: '5', name: 'a pale hovering runestone', noun: 'runestone', type: '')]
    expect(reason).to eq(:runestone)
    room.loot = [OpenStruct.new(id: '6', name: 'a sticky web', noun: 'web', type: '')]
    expect(reason).to eq(:web)
  end

  it "clears a web by Spell Cleave when Lich's CMan says it is available, with no web spell" do
    policy.avoid_webs = true
    room.loot = [OpenStruct.new(id: '6', name: 'a sticky web', noun: 'web', type: '')]
    expect(reason).to be_nil
    allow(described_class).to receive(:cman_available?).with('Spell Cleave').and_return(true)
    expect(reason).to eq(:web)
  end

  it 'reads the grounded and magical debuffs' do
    me.debuff_names = ['Rooted']
    policy.cleanse_grounded = true
    expect(reason).to be_nil
    allow(described_class).to receive(:cman_known?).with('Retreat').and_return(true)
    expect(reason).to eq(:grounded)
    me.debuff_names = ['Confusion']
    policy.cleanse_magical = true
    spell(417)
    expect(reason).to eq(:magical)
  end
end

RSpec.describe EO::Engine::Behaviors::Cleanse do
  let(:me) do
    OpenStruct.new(wounds: {}, able_to_cast?: true, poisoned?: true, diseased?: false, stunned?: false, webbed?: false, bound?: false, hidden?: false,
                   dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false, stamina: 100, blessings_ranks: 0, debuff_names: [])
  end
  let(:spells) { { 114 => CleanseSpell.new(num: 114, known: true, affordable: true, active: false) } }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: '77', noun: 'katana'), left: OpenStruct.new(id: nil, noun: '')) }
  let(:room) { OpenStruct.new(id: 1, title: '[Kobold Village]', loot: [], targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room, hands: hands) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(cleanse_poison: true, recover_disarmed: true) }
  let(:cleanse) { described_class.new(policy: policy) }

  before do
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    allow(EO::Engine::Cleanse::Predicates).to receive(:cman_known?).and_return(false)
    allow_any_instance_of(EO::Engine::Actions::CleanseAffliction).to receive(:sleep)
    allow_any_instance_of(EO::Engine::Actions::CleanseAffliction).to receive(:send_and_match).and_return(EO::Engine::Actions::Result.new(status: :success, line: 'ok'))
  end

  after { EO::Engine::Events.reset! }

  it 'is priority 5 and casts the poison cure until it clears' do
    expect(cleanse.priority).to eq(5)
    casts = 0
    allow(spells[114]).to receive(:cast) { casts += 1; me[:poisoned?] = casts >= 2 ? false : true; 'x' }
    expect(cleanse.wants_control?(world)).to be true
    expect(cleanse.tick(world).reason).to eq(:poison)
    expect(casts).to eq(2)
    expect(cleanse.wants_control?(world)).to be false
  end

  it 'records a disarm from the watch and runs the recovery from the queue' do
    me[:poisoned?] = false
    cleanse
    EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 1, title: 'Kobold Village')
    expect(cleanse.state.recover.size).to eq(1)
    expect(cleanse.state.recover[0][:known_ids]).to eq(['77'])
    expect(cleanse.wants_control?(world)).to be true
    recover = instance_double(EO::Engine::Actions::CleanseRecover, call: EO::Engine::Actions::Result.new(status: :success, reason: :recovered))
    expect(EO::Engine::Actions::CleanseRecover).to receive(:new).with(world, record: hash_including(noun: 'katana'), policy: policy).and_return(recover)
    expect(cleanse.tick(world).reason).to eq(:recovered)
    expect(cleanse.state.recover).to be_empty
    expect(cleanse.wants_control?(world)).to be false
  end

  describe 'the travelling jobs' do
    let(:trips) { [] }
    let(:travel) do
      lambda do |r|
        t = instance_double(EO::Engine::Travel::Trip)
        # one tick underway, then there
        allow(t).to receive(:tick) { trips << r; r == :never ? nil : (room.id = r; EO::Engine::Actions::Result.new(status: :success)) }
        allow(t).to receive(:suspend!) { trips << :suspended }
        allow(t).to receive(:cancel!)
        t
      end
    end
    let(:cleanse) { described_class.new(policy: policy, travel: travel) }

    before { me[:poisoned?] = false }

    it 'goes back to the disarm room before recovering, a trip tick per engine tick' do
      cleanse
      EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 9, title: 'x')
      recover = instance_double(EO::Engine::Actions::CleanseRecover, call: EO::Engine::Actions::Result.new(status: :success, reason: :recovered))
      allow(EO::Engine::Actions::CleanseRecover).to receive(:new) { |w, **| expect(w.room.id).to eq(9); recover }
      cleanse.wants_control?(world)
      expect(cleanse.tick(world).reason).to eq(:recovered) # trip arrives at once
      expect(trips).to eq([9])
      expect(cleanse.job).to be_nil
    end

    it 'walks to the vat, cleans it, and comes home' do
      world.define_singleton_method(:uid_ids) { |_u| [500] }
      vat = instance_double(EO::Engine::Actions::CleanseVat, call: EO::Engine::Actions::Result.new(status: :success, reason: :vat))
      allow(EO::Engine::Actions::CleanseVat).to receive(:new).and_return(vat)
      cleanse
      EO::Engine::Events.emit(:infected_wound)
      cleanse.wants_control?(world)
      expect(cleanse.tick(world)).to be_nil # there and cleaned; the way home is next
      expect(cleanse.job.stage).to eq(:return)
      expect(cleanse.wants_control?(world)).to be true
      expect(cleanse.tick(world).reason).to eq(:vat)
      expect(trips).to eq([500, 1])
      expect(room.id).to eq(1)
    end

    # Arriving in the room is not the end of the trip: go2 is still
    # restoring gear. Cleanse used to act the moment the room matched, with
    # the trip still on the holder, and the return stage then ticked that
    # same trip, which answered "arrived" from the far room.
    it 'finishes the outbound trip before acting, and comes home on a trip of its own' do
      policy.itchy_curse = true
      policy.safe_room = '77'
      legs = []
      slow = lambda do |r|
        legs << r
        t = instance_double(EO::Engine::Travel::Trip, suspend!: nil, cancel!: nil)
        ticks = 0
        # there on the first tick, go2 still running on the second, done on the third
        allow(t).to receive(:tick) { ticks += 1; room.id = r; ticks < 3 ? nil : EO::Engine::Actions::Result.new(status: :success) }
        t
      end
      curse = instance_double(EO::Engine::Actions::CleanseItchyCurse, call: EO::Engine::Actions::Result.new(status: :success, reason: :scratched))
      allow(EO::Engine::Actions::CleanseItchyCurse).to receive(:new).and_return(curse)
      cleanse = described_class.new(policy: policy, travel: slow)
      EO::Engine::Events.emit(:itchy_curse)
      cleanse.wants_control?(world)
      expect(cleanse.tick(world)).to be_nil
      expect(room.id).to eq(77)
      expect(cleanse.tick(world)).to be_nil # in the room, trip still underway
      expect(curse).not_to have_received(:call)
      expect(cleanse.job.stage).to eq(:go)
      expect(cleanse.tick(world)).to be_nil # trip done, the curse scratched, the way home next
      expect(curse).to have_received(:call).once
      expect(cleanse.job.stage).to eq(:return)
      expect(legs).to eq([77])
      expect(cleanse.tick(world)).to be_nil
      expect(legs).to eq([77, 1]) # a trip home of its own
      expect(room.id).to eq(1)
      2.times { cleanse.tick(world) }
      expect(cleanse.job).to be_nil
      expect(room.id).to eq(1)
    end

    it 'ends the job when the safe room cannot be reached, and reports a failed way home' do
      policy.itchy_curse = true
      policy.safe_room = '77'
      failing = ->(_r) { false }
      stuck = described_class.new(policy: policy, travel: failing)
      EO::Engine::Events.emit(:itchy_curse)
      stuck.wants_control?(world)
      expect(stuck.tick(world).reason).to eq(:could_not_reach)
      expect(stuck.job).to be_nil
      expect(described_class.new(policy: EO::Engine::Cleanse::Policy.new(itchy_curse: true, safe_room: ''), travel: failing).send(:run_queued, OpenStruct.new(room: room, nearest_safe_room: nil), { event: :itchy_curse }).reason).to eq(:no_safe_room)
    end

    it 'never runs the job in the wrong room when a trip spends its attempts, and reports a spent way home' do
      spent = lambda do |_r|
        t = instance_double(EO::Engine::Travel::Trip, cancel!: nil, suspend!: nil)
        allow(t).to receive(:tick) { EO::Engine::Actions::Result.new(status: :failed, reason: :could_not_reach) }
        t
      end
      stuck = described_class.new(policy: policy, travel: spent)
      expect(EO::Engine::Actions::CleanseRecover).not_to receive(:new)
      EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 9, title: 'x')
      stuck.wants_control?(world)
      expect(stuck.tick(world).reason).to eq(:could_not_reach)
      expect(stuck.job).to be_nil

      # the way to the vat arrives, the way home is spent
      world.define_singleton_method(:uid_ids) { |_u| [500] }
      vat = instance_double(EO::Engine::Actions::CleanseVat, call: EO::Engine::Actions::Result.new(status: :success, reason: :vat))
      allow(EO::Engine::Actions::CleanseVat).to receive(:new).and_return(vat)
      legs = [travel, spent]
      stuck_home = described_class.new(policy: policy, travel: ->(r) { legs.shift.call(r) })
      complaints = []
      EO::Engine::Events.on(:cleanse_stuck) { |e| complaints << e.data[:reason] }
      EO::Engine::Events.emit(:infected_wound)
      stuck_home.wants_control?(world)
      expect(stuck_home.tick(world)).to be_nil
      expect(stuck_home.tick(world).reason).to eq(:vat)
      expect(complaints).to eq(['Could not return to 1 after use_vat'])
    end

    it 'suspends the trip when preempted and resumes it' do
      cleanse
      never = described_class.new(policy: policy, travel: ->(_r) { travel.call(:never) })
      EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 9, title: 'x')
      never.wants_control?(world)
      expect(never.tick(world)).to be_nil
      never.preempted!(world)
      expect(trips).to eq([:never, :suspended])
      expect(never.wants_control?(world)).to be true
      never.tick(world)
      expect(trips.last).to eq(:never)
      never.cancel!
      expect(never.job).to be_nil
    end
  end

  it 'ignores a disarm when recovery is off' do
    policy.recover_disarmed = false
    cleanse
    EO::Engine::Events.emit(:disarm_seen, kind: :recover, noun: 'katana', hands: hands, room_id: 1, title: 'x')
    expect(cleanse.state.queue).to be_empty
  end

  it 'queues the hive trap with its room and clears it when handled' do
    me[:poisoned?] = false
    policy.hive_traps_ground = true
    cleanse
    EO::Engine::Events.emit(:hive_trap, kind: :hive_traps_ground, room_id: 1)
    expect(cleanse.state.hive_trap_room).to eq(1)
    trap = instance_double(EO::Engine::Actions::CleanseHiveTrap, call: EO::Engine::Actions::Result.new(status: :success, reason: :clear))
    expect(EO::Engine::Actions::CleanseHiveTrap).to receive(:new).and_return(trap)
    cleanse.wants_control?(world)
    expect(cleanse.tick(world).reason).to eq(:clear)
  end
end

RSpec.describe EO::Engine::Actions::CleanseWebBound do
  let(:me) { OpenStruct.new(dead?: false, muckled?: true, webbed?: true, bound?: false, stunned?: false, in_rt?: false, in_cast_rt?: false, stamina: 100) }
  let(:world) { OpenStruct.new(me: me, spell: {}) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(avoid_webs: true) }

  it 'sends Escape Artist while webbed, the technique that removes the web' do
    allow(EO::Engine::Cleanse::Predicates).to receive(:cman_known?).and_return(false)
    allow(EO::Engine::Cleanse::Predicates).to receive(:feat_available?).with('escapeartist', min_rank: 5).and_return(true)
    action = described_class.new(world, policy: policy)
    allow(action).to receive(:settle_rt)
    expect(EO::Engine::Actions::Maneuver).to receive(:new)
      .with(world, hash_including(category: :feat, name: 'escapeartist', escapes: %i[webbed bound]))
      .and_return(instance_double(EO::Engine::Actions::Maneuver, call: EO::Engine::Actions::Result.new(status: :success, acted: true)))
    expect(action.call).to be_success
  end
end

RSpec.describe EO::Engine::Actions::CleanseRally do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false) }
  let(:spells) { {} }
  let(:world) { OpenStruct.new(me: me, spell: spells) }
  let(:sent) { [] }

  def rally
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:sleep)
    # Lich's Mana.pulse (#1580): pulses only when the spell is unaffordable
    allow(Lich::Gemstone::Mana).to receive(:pulse) do |spell, **|
      next false if spell.nil? || spell.affordable?

      sent << 'mana pulse'
      spell.affordable = true
      true
    end
    action
  end

  # Rally sits ahead of :stun and :web_bound in the reason order, so a
  # rally that cannot act blocks the means that could. A refused pulse
  # (mental fatigue, already full, mana control untrained) leaves us where
  # we were: nothing was sent, so that is a skip, not a failure for the
  # repeated-failures watchdog to count.
  it 'skips when the pulse cannot make 1040 affordable' do
    spells[1040] = CleanseSpell.new(num: 1040, known: true, affordable: false, active: false)
    action = described_class.new(world)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:sleep)
    allow(Lich::Gemstone::Mana).to receive(:pulse).and_return(false) # the game refuses
    result = action.call
    expect(result.reason).to eq(:unaffordable)
    expect(result.status).to eq(:skipped)
    expect(result).not_to be_failed
    expect(spells[1040].casts).to eq(0)
  end

  it 'casts 1040, pulsing mana first when it cannot afford it' do
    spells[1040] = CleanseSpell.new(num: 1040, known: true, affordable: true, active: false)
    expect(rally.call.reason).to eq(:rally_1040)
    expect(spells[1040].casts).to eq(1)
    expect(sent).to be_empty
    spells[1040].affordable = false
    expect(rally.call.reason).to eq(:rally_1040)
    expect(sent).to eq(['mana pulse'])
    expect(spells[1040].casts).to eq(2)
  end

  it 'refuses without the spell' do
    expect(rally.call.reason).to eq(:unknown_spell)
  end
end

RSpec.describe EO::Engine::Actions::CleanseRecover do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, kneeling?: false, standing?: true, wounds: {}) }
  let(:hands) { OpenStruct.new(right: OpenStruct.new(id: nil, name: 'Empty', noun: ''), left: OpenStruct.new(id: '5', name: 'a shield', noun: 'shield')) }
  let(:room) { OpenStruct.new(id: 1, title: 'x', targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, room: room, hands: hands, spell: {}) }
  let(:record) { { noun: 'katana', known_ids: ['5'], room_id: 1, title: 'Kobold Village' } }
  let(:sent) { [] }

  before do
    me.define_singleton_method(:spell_active?) { |_n| false }
    allow(EO::Engine::Cleanse::Casting).to receive(:able?).and_return(false)
  end

  def recover
    action = described_class.new(world, record: record, policy: EO::Engine::Cleanse::Policy.new)
    # the stand is Actions::Stand's
    allow_any_instance_of(EO::Engine::Actions::Stand).to receive(:call) { sent << 'stand'; me[:standing?] = true; EO::Engine::Actions::Result.new(status: :success) }
    allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'ok' }
    allow(action).to receive(:send_and_match) { |cmd, _rx, **| sent << cmd; (me[:kneeling?] = true; me[:standing?] = false) if cmd == 'kneel'; EO::Engine::Actions::Result.new(status: :success, line: 'You kneel.') }
    allow(action).to receive(:sleep)
    allow(action).to receive(:bonded?).and_return(false)
    allow(action).to receive(:fill_hands)
    allow(action).to receive(:stance_defensive)
    action
  end

  # ecleanse 1176 calls Feat.weapon_bonding, which does not exist: the
  # module exposes [], known?, affordable?, available? and use, and defines
  # no method_missing (psms/feat.rb 294). The call raised NoMethodError on
  # every character and the rescue swallowed it, so a bonded weapon with no
  # 1625 was never recognised. The spec stubs the real reader, not bonded?.
  # settle_rt is not a wait primitive: it returns at once when no roundtime
  # is pending, so `settle_rt until ...` yielded nothing and pinned a core
  # for the whole ten-second bonded-weapon wait. It was the engine's only
  # such construct. ecleanse polls with Util.wait_rt, which is 0.4 s of
  # sleep per pass (ecleanse 1176-1180, 1826).
  it 'polls the bonded-weapon wait with a sleep, never a bare settle_rt' do
    source = File.read(File.expand_path('../../scripts/eohunter/cleanse.rb', __dir__))
    expect(source).not_to match(/settle_rt (?:until|while) /)
    expect(source).to match(/sleep [\d.]+ until recovered\?/)
  end

  describe 'the bonded-weapon path' do
    def bonded_action
      action = described_class.new(world, record: record, policy: EO::Engine::Cleanse::Policy.new)
      allow(action).to receive(:send_through_ladder) { |cmd| sent << cmd; 'ok' }
      allow(action).to receive(:sleep)
      allow(action).to receive(:settle_rt)
      allow(action).to receive(:fill_hands)
      allow(action).to receive(:stance_defensive)
      action
    end

    it 'is taken at weapon bonding rank 5 with no 1625' do
      stub_const('Lich::Gemstone::Feat', Module.new do
        def self.known?(name, min_rank: 1) = name == 'weapon_bonding' && min_rank <= 5
      end)
      expect(bonded_action.send(:bonded?)).to be true
    end

    it 'is not taken below rank 5' do
      stub_const('Lich::Gemstone::Feat', Module.new do
        def self.known?(name, min_rank: 1) = name == 'weapon_bonding' && min_rank <= 3
      end)
      expect(bonded_action.send(:bonded?)).to be false
    end

    it 'falls back to 1625 when Lich cannot answer' do
      stub_const('Lich::Gemstone::Feat', Module.new do
        def self.known?(*, **) = raise(ArgumentError, 'unknown feat')
      end)
      expect(bonded_action.send(:bonded?)).to be false
      world.spell[1625] = CleanseSpell.new(num: 1625, known: true, affordable: true, active: false)
      expect(bonded_action.send(:bonded?)).to be true
    end
  end

  it 'kneels and recovers until the game confirms, then stands and refills' do
    action = recover
    tries = 0
    allow(action).to receive(:command_lines) { tries += 1; tries == 2 ? ['You spy a katana and recover it!'] : ['You continue to intently search the area'] }
    result = action.call
    expect(result).to be_success
    expect(result.reason).to eq(:recovered)
    expect(sent.first).to eq('stow all')
    expect(sent.count('kneel')).to eq(1)
    expect(sent.last).to eq('stand')
  end

  it 'treats a new item in hand as recovered when no message comes, and gives up after ten' do
    action = recover
    allow(action).to receive(:command_lines) { hands.right = OpenStruct.new(id: '9', name: 'a katana', noun: 'katana'); [] }
    expect(action.call.reason).to eq(:recovered)
    hands.right = OpenStruct.new(id: nil, name: 'Empty', noun: '')
    other = recover
    allow(other).to receive(:command_lines).and_return([])
    expect(other.call.reason).to eq(:not_recovered)
  end

  it 'stops and reports when unable to search' do
    action = recover
    stuck = []
    EO::Engine::Events.on(:cleanse_stuck) { |e| stuck << e.data[:reason] }
    allow(action).to receive(:command_lines).and_return(["You're not in any condition to be searching around."])
    expect(action.call.reason).to eq(:cannot_search)
    expect(stuck.first).to match(/katana is in room 1/)
  ensure
    EO::Engine::Events.reset!
  end

  # The trip to the disarm room belongs to the job that wraps this action,
  # so being elsewhere is a refusal, not something to fix mid-search. It
  # used to call an @travel that Base never sets: whenever go2 landed a
  # room short, the search raised NoMethodError on nil straight out of the
  # tick and the engine stopped with :engine_error.
  it 'refuses rather than travelling when the search starts in the wrong room' do
    room.id = 2
    action = recover
    allow(action).to receive(:command_lines).and_return([])
    expect { @result = action.call }.not_to raise_error
    expect(@result.reason).to eq(:wrong_room)
    expect(sent).not_to include('recover item')
  end
end

# settle_room casts one defensive spell before a recovery, and every
# recovery starts with it. Its 709 branch named Targets::APPENDAGE_NOUNS,
# which was defined nowhere: with use_709 on and the earlier branches
# false, the constant lookup raised NameError before any command went
# out, taking the engine down at the top of a disarm recovery.
RSpec.describe EO::Engine::Actions::CleanseSettleRoom do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, able_to_cast?: true) }
  let(:spells) { { 709 => CleanseSpell.new(num: 709, known: true, affordable: true, active: false) } }
  let(:kobold) { OpenStruct.new(id: '1', name: 'a kobold', noun: 'kobold') }
  # settle_room refuses a quiet room, so something is always in the fight
  let(:room) { OpenStruct.new(id: 1, creatures: [], targets: [kobold]) }
  let(:world) { OpenStruct.new(me: me, spell: spells, room: room) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(use_709: true) }

  before do
    %i[effect_active? cooldown_active? spell_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
  end

  def settle
    action = described_class.new(world, policy: policy)
    allow(action).to receive(:sleep)
    allow(action).to receive(:mana_pulse)
    action
  end

  it 'casts Grasp of the Grave when the room holds no appendage' do
    room.creatures = [kobold]
    expect { @result = settle.call }.not_to raise_error
    expect(spells[709].casts).to eq(1)
    expect(@result).to be_success
  end

  it 'holds the grasp when a creature in the room is an appendage, which has no legs to grab' do
    # Matched on the noun: Lich's name carries the article and any
    # adjectives ("a writhing tentacle"), which the anchored pattern
    # would never match.
    tentacle = OpenStruct.new(id: '2', name: 'a writhing tentacle', noun: 'tentacle')
    room.creatures = [kobold, tentacle]
    settle.call
    expect(spells[709].casts).to eq(0)

    pincer = OpenStruct.new(id: '3', name: 'a snapping pincer', noun: 'pincer')
    room.creatures = [kobold, pincer]
    settle.call
    expect(spells[709].casts).to eq(0)
  end
end

# Every hazard predicate answers nil when the object has left the room,
# and the actions dereference its id in their own preconditions. The
# predicates run once for wants_control? and again when the action is
# built, so a cloud that is looted or expires between the two used to
# raise NoMethodError out of the tick.
RSpec.describe 'EO::Engine::Behaviors::Cleanse hazards that vanish mid-tick' do
  let(:me) do
    OpenStruct.new(wounds: {}, able_to_cast?: true, poisoned?: false, diseased?: false, stunned?: false, webbed?: false,
                   bound?: false, hidden?: false, dead?: false, muckled?: false, in_rt?: false, in_cast_rt?: false,
                   stamina: 100, blessings_ranks: 0, debuff_names: [])
  end
  let(:room) { OpenStruct.new(id: 1, title: 'x', loot: [], targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, spell: {}, room: room, hands: OpenStruct.new(right: OpenStruct.new(id: nil), left: OpenStruct.new(id: nil))) }
  let(:policy) { EO::Engine::Cleanse::Policy.new(break_runestone: true) }
  let(:cleanse) { EO::Engine::Behaviors::Cleanse.new(policy: policy) }

  before do
    %i[debuff_active? cooldown_active? spell_active? effect_active?].each { |m| me.define_singleton_method(m) { |_n| false } }
    allow(EO::Engine::Cleanse::Predicates).to receive(:cman_known?).and_return(false)
  end

  after { EO::Engine::Events.reset! }

  it 'ticks silently when the hazard it claimed control for is gone by the time it acts' do
    room.loot = [OpenStruct.new(id: '42', name: 'a pale hovering runestone', noun: 'runestone', type: '')]
    expect(cleanse.wants_control?(world)).to be true

    # looted, expired, or another hunter cleared it between the two reads
    room.loot = []
    expect { @result = cleanse.tick(world) }.not_to raise_error
    expect(@result).to be_nil
  end
end

# CleanseHazard's last rung is Spell Cleave or Spell Thieve. It discarded
# the helper's answer and always reported :cleaved, so a hazard still in
# the room was recorded as cleansed and a genuinely stuck one was hidden
# from the repeated-failures watchdog. The docstring already promised
# :no_means; only the code did not.
RSpec.describe EO::Engine::Actions::CleanseHazard do
  let(:me) { OpenStruct.new(dead?: false, in_rt?: false, in_cast_rt?: false, stunned?: false, webbed?: false) }
  let(:web) { OpenStruct.new(id: '9', name: 'a sticky web', noun: 'web') }
  let(:room) { OpenStruct.new(id: 1, loot: [web], targets: [], creatures: []) }
  let(:world) { OpenStruct.new(me: me, room: room, spell: {}) }
  let(:state) { EO::Engine::Cleanse::State.new }

  def hazard
    action = described_class.new(world, kind: :web, object: web, state: state,
                                        policy: EO::Engine::Cleanse::Policy.new)
    allow(action).to receive(:settle_rt)
    allow(action).to receive(:sleep)
    allow(action).to receive(:target_hazard).and_return(true)
    action
  end

  before { allow(EO::Engine::Cleanse::Casting).to receive(:able?).and_return(false) }

  it 'reports no means when neither Spell Cleave nor Spell Thieve is available' do
    allow(EO::Engine::Cleanse::Predicates).to receive(:can_cleave?).and_return(false)
    allow(EO::Engine::Cleanse::Predicates).to receive(:can_thieve?).and_return(false)
    result = hazard.call
    expect(result).to be_failed
    expect(result.reason).to eq(:no_means)
  end

  it 'carries a refused maneuver through instead of reporting a cleanse' do
    allow(EO::Engine::Cleanse::Predicates).to receive(:can_cleave?).and_return(true)
    action = hazard
    refused = EO::Engine::Actions::Result.new(status: :failed, reason: :cman_refused)
    allow(action).to receive(:cman_use).and_return(refused)
    expect(action.call.reason).to eq(:cman_refused)
  end

  it 'reports the cleave when the maneuver lands' do
    allow(EO::Engine::Cleanse::Predicates).to receive(:can_cleave?).and_return(true)
    action = hazard
    allow(action).to receive(:cman_use).and_return(EO::Engine::Actions::Result.new(status: :success))
    expect(action.call.reason).to eq(:cleaved)
  end
end
