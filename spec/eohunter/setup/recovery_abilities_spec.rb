# frozen_string_literal: true

require 'ostruct'
require_relative '../../../scripts/eohunter/setup/recovery_abilities'

RSpec.describe EO::HunterSetup::RecoveryAbilities do
  # Stand-ins for Lich's Spell, CMan and Feat, knowing only what is listed.
  def spells(*known)
    Hash.new { |_h, _id| OpenStruct.new(known?: false) }.merge(known.to_h { |id| [id, OpenStruct.new(known?: true)] })
  end

  def cman(ranks = {})
    reader = Object.new
    reader.define_singleton_method(:known?) { |name| ranks.fetch(name, 0).positive? }
    reader.define_singleton_method(:[]) { |name| ranks.fetch(name, 0) }
    reader
  end

  def feat(*known)
    reader = Object.new
    reader.define_singleton_method(:known?) { |name| known.include?(name) }
    reader
  end

  it 'marks what the character cannot use, as ecleanse greys it out, and says why' do
    out = described_class.capture(spells: spells(114, 709), cman: cman('Stun Maneuvers' => 3), feat: feat)
    expect(out).not_to include('cleanse_poison', 'use_709', 'use_stance1')
    expect(out['cleanse_disease']).to eq('You do not know Undisease (113).')
    expect(out['use_919']).to eq("You do not know Wizard's Shield (919).")
    expect(out['use_berserk_stunned']).to eq('You do not know Berserk.')
    expect(out['use_stance2']).to eq('Needs Stun Maneuvers rank 4; you have 3.')
    expect(out['cleanse_magical']).to start_with('Needs a dispel')
    # Not gated: they need no spell or maneuver.
    expect(out.keys).not_to include('itchy_curse', 'hive_traps_ground', 'break_runestone', 'recover_disarmed', 'safe_room')
  end

  it 'counts a cleave or a feat where ecleanse does' do
    out = described_class.capture(spells: spells, cman: cman('Spell Cleave' => 1, 'Retreat' => 1), feat: feat('escapeartist'))
    expect(out).not_to include('dispel_magic', 'avoid_webs', 'cleanse_grounded')
    expect(out).to include('cleanse_magical')
  end

  it 'marks nothing when Lich cannot be read: unknown is not the same as cannot' do
    expect(described_class.capture(spells: nil, cman: nil, feat: nil)).to eq({})
    broken = Object.new
    broken.define_singleton_method(:[]) { |_| raise 'infomon gone' }
    expect(described_class.capture(spells: broken, cman: cman, feat: feat)).to eq({})
  end
end
