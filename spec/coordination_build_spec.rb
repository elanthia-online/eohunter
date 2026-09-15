# frozen_string_literal: true

require 'tmpdir'
require_relative '../tools/build_coordination'

RSpec.describe EOCoordination::Build do
  let(:root) { File.expand_path('..', __dir__) }
  let(:result) { described_class.build(root: root, sha: 'abc1234') }
  let(:built) { result.source }

  it 'builds valid Ruby without disk-relative library loads' do
    expect { RubyVM::InstructionSequence.compile(built, 'libeocoordination.lic') }.not_to raise_error
    expect(built).not_to include('require_relative')
    expect(built).not_to include("base = File.join(SCRIPT_DIR, 'eocoordination')")
    expect(built).to include('EO::Coordination.require_version')
  end

  it 'inlines every part in dependency order and maps each section' do
    markers = built.lines.grep(/^# ==== /).map(&:chomp)
    expected = described_class::PARTS.map { |part| "# ==== eocoordination/#{part}.rb ====" }
    expect(markers).to eq(expected + ['# ==== libeocoordination.lic ===='])
    expect(result.sections.keys).to eq(described_class::PARTS.map { |part| "eocoordination/#{part}.rb" })
  end

  it 'writes the library and its complete map' do
    Dir.mktmpdir do |dir|
      out = File.join(dir, 'dist', 'libeocoordination.lic')
      expect(described_class.write(root: root, out: out, sha: 'abc1234')).to eq(out)
      expect(File.read(out, mode: 'rb')).to eq(built)
      expect(File.readlines("#{out}.map").size).to eq(described_class::PARTS.size)
    end
  end
end
