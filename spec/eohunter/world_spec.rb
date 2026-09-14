# frozen_string_literal: true

require 'ostruct'
require_relative 'engine_helper'

RSpec.describe EO::Engine::World do
  it 'reads named message availability fresh across definition reloads' do
    messages = double('Messages', events: [:user_feed_result])
    world = described_class.new
    allow(world).to receive(:messages).and_return(messages)
    expect(world.message_events).to eq([:user_feed_result])
    allow(messages).to receive(:events).and_return(['other_result'])
    expect(world.message_events).to eq([:other_result])
  end

  # Test double mirroring Lich's shapes (GameObj: "Empty"-named hand objects,
  # frozen 'gone' statuses; XMLData: indicator hash of 'y'/'n').
  let(:npc) { Struct.new(:id, :noun, :name, :status) }
  let(:hand) { Struct.new(:id, :noun, :name) }

  let(:xmldata) do
    OpenStruct.new(
      health: 120, max_health: 150, mana: 40, max_mana: 100,
      stamina: 80, max_stamina: 100, spirit: 10, max_spirit: 10,
      roundtime_end: 0, cast_roundtime_end: 0, server_time_offset: 0,
      indicator: { 'IconSTANDING' => 'y', 'IconSTUNNED' => 'n', 'IconDEAD' => 'n',
                   'IconWEBBED' => 'n', 'IconPRONE' => 'n', 'IconHIDDEN' => 'n' },
      stance_text: 'offensive', stance_value: 0,
      room_id: 8003, room_title: '[Kobold Village]', room_count: 7,
      room_exits: %w[north east], prepared_spell: 'None'
    )
  end

  let(:kobold) { npc.new('1234', 'kobold', 'a kobold', nil) }
  let(:dead_gnoll) { npc.new('5678', 'gnoll', 'a gnoll worker', 'dead') }
  let(:gone_rat) { npc.new('9999', 'rat', 'a giant rat', 'gone') }

  let(:gameobj) do
    double('GameObj',
           npcs: [kobold, dead_gnoll, gone_rat],
           pcs: nil,
           loot: nil,
           right_hand: hand.new('7777', 'sword', 'a steel short sword'),
           left_hand: hand.new(nil, nil, 'Empty'))
  end

  let(:spell_mod) { double('Spell', active: [OpenStruct.new(num: 401), OpenStruct.new(num: 414)]) }
  let(:map_mod)   { double('Map', current: OpenStruct.new(id: 288)) }
  let(:stats_mod) { double('Stats', level: 5, profession: 'Warrior') }

  subject(:world) do
    w = described_class.new
    allow(w).to receive_messages(xmldata: xmldata, gameobj: gameobj, spell: spell_mod,
                                 map: map_mod, stats: stats_mod)
    w
  end

  describe 'Me' do
    it 'reads vitals and percentages' do
      expect(world.me.health).to eq(120)
      expect(world.me.health_pct).to eq(80)
      expect(world.me.mana_pct).to eq(40)
    end

    it 'guards percentage against zero max' do
      xmldata.max_mana = 0
      expect(world.me.mana_pct).to eq(0)
    end

    it 'computes remaining RT with server offset, clamped at zero' do
      now = Time.now
      allow(world).to receive(:clock).and_return(double(now: now))
      xmldata.roundtime_end = now.to_f + 3
      xmldata.server_time_offset = 0
      expect(world.me.rt).to be_within(0.01).of(3.0)
      expect(world.me.in_rt?).to be(true)

      xmldata.roundtime_end = now.to_f - 5
      expect(world.me.rt).to eq(0.0)
      expect(world.me.in_rt?).to be(false)
    end

    it "reads posture from Lich's indicator readers and the muckle states from Status" do
      status = double('Status', dead?: false, stunned?: false, webbed?: false, sleeping?: false)
      allow(world).to receive_messages(status: status, standing?: true, prone?: false, hidden?: false)
      expect(world.me.standing?).to be(true)
      expect(world.me.prone?).to be(false)
      expect(world.me.stunned?).to be(false)
      allow(status).to receive(:stunned?).and_return(true)
      expect(world.me.stunned?).to be(true)
    end

    it "reads the exact experience numbers from Lich's Experience and the mind bar from XMLData" do
      allow(world).to receive(:experience).and_return(double('Experience', fxp_current: 1_234, fxp_max: 2_500, exp: 987_654, until_next: 12_346, percent_fxp: 49.36))
      xmldata.mind_text = 'muddled'
      xmldata.mind_value = 49
      expect(world.me.fxp).to eq(1_234)
      expect(world.me.fxp_max).to eq(2_500)
      expect(world.me.fxp_pct).to eq(49)
      expect(world.me.exp).to eq(987_654)
      expect(world.me.until_next).to eq(12_346)
      expect(world.me.mind_text).to eq('muddled')
      expect(world.me.mind_value).to eq(49)
    end

    it "reads the mind words from Lich's checksaturated and checkfried" do
      allow(world).to receive_messages(saturated?: true, fried?: true)
      expect(world.me.saturated?).to be(true)
      expect(world.me.mind_fried?).to be(true)
    end

    it "reads whether a creature hid here from Lich's Overwatch" do
      stub_const('Lich::Gemstone::Overwatch', double('Overwatch', hiders?: true))
      expect(world.hiders?).to be(true)
    end

    it "reads the combat dialog's hidden ids from GameObj.hidden_targets" do
      allow(gameobj).to receive(:hidden_targets).and_return(%w[77 78])
      expect(world.hidden_target_ids).to eq(%w[77 78])
    end

    it "prices a Voln symbol through Lich's OrderOfVoln reader, by spell number" do
      voln = double('OrderOfVoln', all: [{ spell_number: 9816, short_name: 'supremacy' }, { spell_number: 9805, short_name: 'courage' }])
      allow(voln).to receive(:affordable?) { |name| name == 'courage' }
      stub_const('Lich::Gemstone::Societies::OrderOfVoln', voln)
      expect(world.voln_symbol_affordable?(9805)).to be(true)
      expect(world.voln_symbol_affordable?(9816)).to be(false)
      expect(world.voln_symbol_affordable?(9999)).to be(true)
    end

    it "reads whether the group is open from Lich's Group" do
      stub_const('Lich::Gemstone::Group', double('Group', open?: true))
      expect(world.group_open?).to be(true)
    end

    it "reads the STOW DEFAULT container from Lich's StowList, checking it only when stale" do
      pack = OpenStruct.new(id: '55', name: 'a canvas backpack')
      list = double('StowList', valid?: false, default: pack)
      expect(list).to receive(:check).with(silent: true, quiet: true)
      stub_const('Lich::Gemstone::StowList', list)
      expect(world.stow_default).to equal(pack)

      fresh = double('StowList', valid?: true, default: nil)
      expect(fresh).not_to receive(:check)
      stub_const('Lich::Gemstone::StowList', fresh)
      expect(world.stow_default).to be_nil
    end

    it 'lists active spell numbers' do
      expect(world.me.active_spell_numbers).to eq([401, 414])
    end
  end

  describe 'RoomView' do
    it "names bigshot's four hazard families from the object list, by toggle" do
      cloud = npc.new('1', 'cloud', 'a noxious gas cloud', nil)
      circle = npc.new('2', 'circle', 'intense shimmering circle', nil)
      vine = npc.new('3', 'vine', 'a thorny vine', nil)
      web = npc.new('4', 'web', 'a sticky web', nil)
      void = npc.new('5', 'void', 'a black void', nil)
      fog = npc.new('6', 'fog', 'a thick fog', nil)
      allow(gameobj).to receive(:loot).and_return([cloud, circle, vine, web, void, fog])
      expect(world.room.hazards.map(&:id)).to eq(%w[1 2 3 4 5])
      expect(world.room.hazards(kinds: [:vine]).map(&:id)).to eq(['3'])
      expect(world.room.hazardous?(kinds: [])).to be false
    end

    # bigshot's should_flee? scans GameObj.loot for these four families and
    # nothing else; the GameObj.npcs scan right below it is for the
    # always_flee_from name list, which lives on Flee::Policy here. Scanning
    # creatures too made the room permanently hazardous - a vine or web
    # creature stays on the npc list after it dies, so the flee trigger
    # never cleared and the hunter fled the room for good.
    it 'does not read a hazard-named creature as a room hazard' do
      vine_creature = npc.new('9', 'vine', 'a thorny vine', 'dead')
      web_creature = npc.new('10', 'web', 'a sticky web', nil)
      allow(gameobj).to receive(:loot).and_return([])
      allow(gameobj).to receive(:npcs).and_return([vine_creature, web_creature])

      expect(world.room.hazards).to be_empty
      expect(world.room.hazardous?).to be false
    end

    it 'filters dead and gone creatures out of live_creatures' do
      expect(world.room.creatures.size).to eq(3)
      expect(world.room.live_creatures).to eq([kobold])
    end

    it 'handles nil GameObj registries as empty' do
      expect(world.room.players).to eq([])
      expect(world.room.loot).to eq([])
      expect(world.room.empty_of_players?).to be(true)
    end

    # The (outside) routine modifier read this. RoomView never defined it,
    # so the guarded call was always false: (outside) skipped every time
    # and (!outside) never did. Lich's own outside? reads the exits line
    # rather than the map, so it is right in an unmapped room too
    # (global_defs.rb 1214).
    it 'reads outside from the exits line, the way Lich does' do
      xmldata.room_exits_string = 'Obvious paths: north, east'
      expect(world.room.outside?).to be true
      xmldata.room_exits_string = 'Obvious exits: north, east'
      expect(world.room.outside?).to be false
      xmldata.room_exits_string = nil
      expect(world.room.outside?).to be false
    end

    it 'exposes both room identities (Lich id and game UID)' do
      expect(world.room.uid).to eq(8003)
      expect(world.room.id).to eq(288)
    end
  end

  describe 'Hands' do
    it "treats Lich's Empty-named nil-id object as an empty hand" do
      expect(world.hands.right_empty?).to be(false)
      expect(world.hands.left_empty?).to be(true)
      expect(world.hands.empty?).to be(false)
    end

    it 'matches held items by noun pattern' do
      expect(world.hands.holding?(/sword/)).to be(true)
      expect(world.hands.holding?(/runestaff/)).to be(false)
    end
  end

  describe 'claim_mine?' do
    it "reads Lich's Claim.mine?" do
      allow(world).to receive(:claim).and_return(double('Claim', mine?: false))
      expect(world.claim_mine?).to be(false)

      allow(world).to receive(:claim).and_return(double('Claim', mine?: true))
      expect(world.claim_mine?).to be(true)
    end

    it 'resolves the constant at Lich::Claim, where core defines it' do
      stub_const('Lich::Claim', double('Claim', mine?: false))
      expect(world.claim_mine?).to be(false)
    end

    it 'reads as ours only when Claim is not loaded' do
      allow(world).to receive(:claim).and_raise(NameError, 'uninitialized constant Lich::Claim')
      expect(world.claim_mine?).to be(true)
    end
  end

  # Object defines frozen?, so respond_to?(:frozen?) is true of every
  # object: the old guard always passed and called Object#frozen? on the
  # Status module itself - whether the module is literally frozen, never a
  # character state. Cleanse and Survival both gate on this.
  describe '#frozen?' do
    it 'is false while Lich Status declares no frozen? of its own' do
      status = Module.new do
        def self.webbed? = false
        def self.sleeping? = false
      end
      status.freeze # the module IS frozen; the character is not
      expect(described_class::Me.new(OpenStruct.new(status: status)).frozen?).to be false
    end

    it 'answers Status once it grows one' do
      status = Module.new { def self.frozen? = true }
      expect(described_class::Me.new(OpenStruct.new(status: status)).frozen?).to be true
    end
  end

  # &. then .to_i turned "not on the map" into 0, which is the value the
  # doc reserves for a real room; the rescue could never fire because
  # nothing raised.
  describe '#room_uid' do
    it 'is nil for a room that is not on the map' do
      world = described_class.allocate
      allow(world).to receive(:map).and_return({})
      expect(world.room_uid(999)).to be_nil
    end

    it 'is the uid for a room that is' do
      world = described_class.allocate
      allow(world).to receive(:map).and_return({ 7 => OpenStruct.new(uid: [7503252]) })
      expect(world.room_uid(7)).to eq(7503252)
    end
  end
end
