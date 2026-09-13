# frozen_string_literal: true

require_relative 'engine_helper'
require_relative 'support/fake_world'

RSpec.describe 'Engine pause ownership' do
  let(:engine) { EO::Engine::Engine.new(world: FakeWorld.new, behaviors: [], interval: 0) }

  it 'preserves legacy return values and manual pause semantics' do
    expect(engine.pause!).to be true
    expect(engine.status[:state]).to eq(:held)
    expect(engine.resume!).to be false
    expect(engine.status[:state]).to eq(:running)
  end

  it 'keeps independently owned holds until each owner releases its own' do
    owner = Object.new
    engine.pause!(owner: owner)
    engine.pause!
    engine.resume!(owner: Object.new)
    engine.resume!
    expect(engine.paused?).to be true
    engine.resume!(owner: owner)
    expect(engine.paused?).to be false
  end

  it 'does not accumulate duplicate pauses for one owner' do
    3.times { engine.pause! }
    engine.resume!
    expect(engine.paused?).to be false
  end
end
