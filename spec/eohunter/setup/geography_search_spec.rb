# frozen_string_literal: true

require 'ostruct'
require_relative '../../../scripts/eohunter/setup/geography'
require_relative '../engine_helper'

RSpec.describe EO::HunterSetup::Geography, 'finding a place to look at' do
  let(:rooms) do
    [OpenStruct.new(id: 1, uid: [101], title: ['[Town Square, Centre]'], location: 'Town', image: 'town.png', image_coords: [0, 0, 10, 10],
                    wayto: {}, tags: ['meta:mapname:Wehnimer\'s Landing']),
     OpenStruct.new(id: 2, uid: [102], title: ['[Town Square, East]'], location: 'Town', image: 'town.png', image_coords: [20, 0, 30, 10], wayto: {}),
     OpenStruct.new(id: 3, uid: [103], title: ['[Mead Hall]'], location: 'Far Village', image: 'far.png', image_coords: [0, 0, 10, 10], wayto: {}),
     OpenStruct.new(id: 4, uid: [104], title: ['[Mead Hall, Kitchen]'], location: 'Far Village', image: 'far.png', image_coords: [20, 0, 30, 10], wayto: {}),
     OpenStruct.new(id: 5, uid: [105], title: ['[Nowhere, Undrawn]'], location: 'Far Village', wayto: {}),
     OpenStruct.new(id: 6, uid: [106], title: ['[Crossing]'], location: 'Far Village', image: 'town.png', image_coords: [40, 0, 50, 10], wayto: {})]
  end
  let(:geography) do
    described_class.new(templates: [], rooms: rooms, uid_resolver: ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) })
  end

  it 'names every sheet and every location, each with the sheet most of it is drawn on' do
    names = geography.area_names
    expect(names.map { |entry| entry[:name] }).to eq(['Far Village', 'Town', "Wehnimer's Landing"])
    expect(names.find { |entry| entry[:name] == 'Far Village' }[:image]).to eq('far.png')
    expect(names.find { |entry| entry[:name] == "Wehnimer's Landing" }[:image]).to eq('town.png')
  end

  it 'finds drawn rooms by part of a title, titles before locations, and never an undrawn one' do
    found = geography.room_search(query: 'mead hall')
    expect(found.map { |room| room[:id] }).to eq([3, 4])
    expect(found.first).to include(image: 'far.png', sheet_label: 'far.png', title: '[Mead Hall]')
    expect(geography.room_search(query: 'far village').map { |room| room[:id] }).to eq([3, 4, 6])
    expect(geography.room_search(query: 'nowhere')).to be_empty
    expect(geography.room_search(query: '   ')).to be_empty
  end

  it 'names the sheets a creature lives on from its rooms, whatever its areas are called' do
    beast = OpenStruct.new(name: 'Beast', areas: [{ name: 'Not A Map Name', uids: [101..102] }, { name: 'Elsewhere', uids: [104] }])
    gnat = OpenStruct.new(name: 'gnat', areas: [{ name: 'Nowhere', uids: [105, 900] }])
    with_creatures = described_class.new(templates: [beast, gnat], rooms: rooms,
                                         uid_resolver: ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) })
    expect(with_creatures.creature_sheets('beast')).to eq([{ id: 'far.png', name: 'far.png' }, { id: 'town.png', name: "Wehnimer's Landing" }])
    expect(with_creatures.creature_sheets('gnat')).to be_empty
    expect(with_creatures.creature_sheets('nobody')).to be_empty
  end

  it 'fences every pocket a creature lives in with the ring just outside it' do
    # Two pockets, 11-12 and 21, each opening onto rooms nothing lives in.
    ring = [OpenStruct.new(id: 10, uid: [], wayto: { '11' => 'east' }),
            OpenStruct.new(id: 11, uid: [211], image: 'wild.png', image_coords: [0, 0, 1, 1], wayto: { '10' => 'west', '12' => 'east' }),
            OpenStruct.new(id: 12, uid: [212], image: 'wild.png', image_coords: [0, 0, 1, 1], wayto: { '11' => 'west', '13' => 'east' }),
            OpenStruct.new(id: 13, uid: [], wayto: { '12' => 'west', '21' => 'east' }),
            OpenStruct.new(id: 21, uid: [221], image: 'wild.png', image_coords: [0, 0, 1, 1], wayto: { '13' => 'west', '22' => 'east' }),
            OpenStruct.new(id: 22, uid: [], wayto: { '21' => 'west' })]
    berserker = OpenStruct.new(name: 'berserker', areas: [{ name: 'Wilds', uids: [211, 212] }, { name: 'Wilds East', uids: [221] }])
    wilds = described_class.new(templates: [berserker], rooms: ring,
                                uid_resolver: ->(uid) { ring.select { |room| room.uid.include?(uid) }.map(&:id) })
    fence = wilds.creature_fence('Berserker')
    expect(fence).to include(room_ids: [11, 12, 21], boundary_ids: [10, 13, 22], pockets: 2)
    # Each area apart, largest first: a hunt walks the one it starts in.
    expect(fence[:areas]).to eq([[11, 12], [21]])
    expect(fence[:sheets].map { |sheet| sheet[:id] }).to eq(['wild.png'])
    expect(wilds.creature_fence('nobody')).to eq(room_ids: [], boundary_ids: [], pockets: 0, areas: [], sheets: [])
  end

  it 'describes a creature for the details popup, leaving out what is not recorded' do
    attack = OpenStruct.new(physical_attacks: [{ name: 'claw', as: 300 }], bolt_spells: [], warding_spells: [], offensive_spells: [],
                            maneuvers: [], special_abilities: [])
    defense = OpenStruct.new(asg: '10', melee: 250, ranged: nil, bolt: nil, udf: nil, wiz_td: 400, immunities: [],
                             defensive_spells: [], defensive_abilities: [], special_defenses: [])
    wolf = OpenStruct.new(name: 'wolf', level: 9, family: 'canine', type: 'quadruped', undead: false, max_hp: 120,
                          attack_attributes: attack, defense_attributes: defense, treasure: { coins: true, skin: 'a wolf pelt' },
                          areas: [{ name: 'Far Village', uids: [103, 104, 999] }])
    found = described_class.new(templates: [wolf], rooms: rooms,
                                uid_resolver: ->(uid) { rooms.select { |room| room.uid.include?(uid) }.map(&:id) }).creature_details('Wolf')
    expect(found[:title]).to eq('wolf, level 9')
    expect(found[:lines]).to eq([[:line, 'canine quadruped'], [:line, 'Max HP: 120'],
                                 [:head, 'Attacks'], [:line, 'Physical: claw (300)'],
                                 [:head, 'Defense'], [:line, 'Armor: 10'], [:line, 'DS: melee 250'], [:line, 'TD: Wizard 400'],
                                 [:head, 'Treasure'], [:line, 'Drops: coins, skin'], [:line, 'Skin: a wolf pelt'],
                                 [:head, 'Lives in'], [:line, 'Far Village: 3 rooms recorded, 2 on the map']])
  end

  it 'takes a room id or a UID as well' do
    expect(geography.room_search(query: '2').map { |room| room[:id] }).to eq([2])
    expect(geography.room_search(query: 'u103').map { |room| room[:id] }).to eq([3])
    expect(geography.room_search(query: 'u105')).to be_empty
  end
end
