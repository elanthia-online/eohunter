# frozen_string_literal: true

require_relative '../spec_helper'

RSpec.describe 'libeocoordination' do
  it 'loads as an inert script library and exposes an explicit version gate' do
    stub_const('SCRIPT_DIR', File.expand_path('../../scripts', __dir__))
    threads = Thread.list

    load File.join(SCRIPT_DIR, 'libeocoordination.lic')

    expect(EO::Coordination::VERSION).to eq('0.1.0')
    expect(EO::Coordination.require_version('0.1.0')).to be(true)
    expect(EO::Coordination::ParserProjection).to be_a(Class)
    expect(Thread.list - threads).to be_empty
  end
end
