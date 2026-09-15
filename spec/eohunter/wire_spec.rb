# frozen_string_literal: true

require_relative 'engine_helper'

# EOHunter.wire installs the front-end handlers. Two pieces of machinery
# it is meant to switch on were never assigned: the engine's interrupt,
# which every wait inside an action checks, and the bus's error reporter,
# without which an exception in any of the ~45 wired handlers vanished
# with no line and no log. The script's flow cannot be executed in a
# spec, so these are pinned in the source.
RSpec.describe 'EOHunter.wire' do
  let(:source) { File.read(File.expand_path('../../scripts/eohunter.lic', __dir__)) }
  let(:wire) { source[/  def self\.wire\(engine, behaviors\)\n.*?\n  end\n/m] }

  it 'gives the actions the engine as their interrupt' do
    expect(wire).to include('Actions::Base.interrupt =')
    expect(wire).to match(/engine\.stopping\?/)
  end

  it 'gives the bus somewhere to report a handler that raises' do
    expect(wire).to include('Events.error_reporter =')
  end

  it 'clears the interrupt on teardown, since it closes over this run' do
    teardown = source[/^unless dry\n  before_dying do\n.*?\n^end\n/m]
    expect(teardown).to include('Actions::Base.interrupt = nil')
  end
end
