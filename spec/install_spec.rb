# frozen_string_literal: true

require 'tmpdir'
require 'fileutils'
require 'open3'
require 'rbconfig'
require_relative '../lib/eohunter/install'

RSpec.describe EOHunter::Install do
  around do |example|
    Dir.mktmpdir('eohunter-install') do |directory|
      @directory = directory
      example.run
    end
  end

  # A Lich install with nothing of eohunter's in it.
  def lich(name = 'Lich5', version: '5.22.0')
    dir = File.join(@directory, name)
    FileUtils.mkdir_p(File.join(dir, 'scripts'))
    FileUtils.mkdir_p(File.join(dir, 'lib'))
    File.write(File.join(dir, 'lich.rbw'), '')
    File.write(File.join(dir, 'lib', 'version.rb'), "LICH_VERSION = '#{version}'\n") if version
    dir
  end

  # A small scripts/ tree standing in for the gem's.
  def payload(version: '1.0.0', parts: %w[engine.rb watch.rb])
    root = File.join(@directory, "payload-#{version}")
    FileUtils.mkdir_p(File.join(root, 'eohunter', 'setup'))
    FileUtils.mkdir_p(File.join(root, 'eocoordination'))
    File.write(File.join(root, 'eohunter.lic'), "=begin\n      required: Lich >= 5.22.0\n=end\n")
    File.write(File.join(root, 'libeocoordination.lic'), "# lib\n")
    File.write(File.join(root, 'eocoordination', 'protocol.rb'), "# protocol\n")
    File.write(File.join(root, 'eohunter', 'setup', 'window.rb'), "# window\n")
    File.write(File.join(root, 'libeo.lic'), "# not shipped\n")
    parts.each { |part| File.write(File.join(root, 'eohunter', part), "# #{part}\n") }
    File.write(File.join(root, 'eohunter', 'engine.rb'), "    VERSION = '#{version}'\n")
    root
  end

  describe 'the payload the real gem carries' do
    it 'is the script, the engine and setup parts, and the coordination library' do
      files = described_class.payload_files
      expect(files).to include('eohunter.lic', 'libeocoordination.lic', 'eohunter/engine.rb',
                               'eohunter/setup/window.rb', 'eocoordination/protocol.rb')
      expect(files).not_to include('libeo.lic')
      expect(files.grep(/\A(?:eohunter|eocoordination)\/|\A(?:eohunter|libeocoordination)\.lic\z/)).to eq(files)
    end

    it 'takes its version from the engine and its Lich requirement from the script header' do
      expect(described_class.version).to match(/\A\d+\.\d+\.\d+\z/)
      expect(described_class.required_lich).to eq('5.22.0')
    end
  end

  describe '.find_lich' do
    it 'takes --lich-dir over LICH_DIR, and refuses one that is not a Lich install' do
      first = lich('First')
      second = lich('Second')
      expect(described_class.find_lich(explicit: first, env: second, candidates: [])).to eq(File.expand_path(first))
      expect(described_class.find_lich(env: second, candidates: [])).to eq(File.expand_path(second))
      expect { described_class.find_lich(explicit: @directory, candidates: []) }
        .to raise_error(described_class::Error, /not a Lich install/)
    end

    it 'finds the one Lich among the usual places, and asks when there are several or none' do
      only = lich('Only')
      expect(described_class.find_lich(env: nil, candidates: [File.join(@directory, 'Nope'), only]))
        .to eq(File.expand_path(only))
      other = lich('Other')
      expect { described_class.find_lich(env: nil, candidates: [only, other]) }
        .to raise_error(described_class::Error, /several Lich installs/)
      expect { described_class.find_lich(env: nil, candidates: []) }
        .to raise_error(described_class::Error, /no Lich install found/)
    end

    it 'looks for the usual directory names under home, Documents and the drives' do
      places = described_class.candidates(home: '/home/me', drives: ['G:/'])
      expect(places).to include('/home/me/Lich5', '/home/me/Documents/Lich5', 'G:/Lich5')
    end
  end

  describe '.install' do
    it 'copies the payload into scripts/, records it, and leaves data/ alone' do
      dir = lich
      FileUtils.mkdir_p(File.join(dir, 'data'))
      File.write(File.join(dir, 'data', 'keep.yaml'), 'mine')
      result = described_class.install(dir, root: payload)
      expect(result[:version]).to eq('1.0.0')
      expect(File.read(File.join(dir, 'scripts', 'eohunter', 'watch.rb'))).to eq("# watch.rb\n")
      expect(File).to exist(File.join(dir, 'scripts', 'eohunter', 'setup', 'window.rb'))
      expect(File).not_to exist(File.join(dir, 'scripts', 'libeo.lic'))
      expect(described_class.manifest(dir)['files'].keys).to match_array(result[:copied])
      expect(File.read(File.join(dir, 'data', 'keep.yaml'))).to eq('mine')
    end

    it 'removes on upgrade a file the newer version dropped, and only that' do
      dir = lich
      described_class.install(dir, root: payload(version: '1.0.0', parts: %w[engine.rb watch.rb old.rb]))
      File.write(File.join(dir, 'scripts', 'other.lic'), 'not ours')
      result = described_class.install(dir, root: payload(version: '1.1.0', parts: %w[engine.rb watch.rb]))
      expect(result[:removed]).to eq(['eohunter/old.rb'])
      expect(File).not_to exist(File.join(dir, 'scripts', 'eohunter', 'old.rb'))
      expect(File).to exist(File.join(dir, 'scripts', 'other.lic'))
      expect(described_class.manifest(dir)['version']).to eq('1.1.0')
    end

    it 'refuses a directory that is not a Lich install' do
      expect { described_class.install(@directory, root: payload) }.to raise_error(described_class::Error)
    end
  end

  describe '.uninstall' do
    it 'removes what it installed and the directories it left empty, and nothing else' do
      dir = lich
      described_class.install(dir, root: payload)
      File.write(File.join(dir, 'scripts', 'other.lic'), 'not ours')
      removed = described_class.uninstall(dir)
      expect(removed).to include('eohunter.lic', 'eohunter/setup/window.rb')
      expect(Dir.children(File.join(dir, 'scripts'))).to eq(['other.lic'])
    end

    it 'refuses when nothing was installed by the gem' do
      expect { described_class.uninstall(lich) }.to raise_error(described_class::Error, /no eohunter install/)
    end
  end

  describe '.check' do
    it 'reports files missing or changed since the install' do
      dir = lich
      described_class.install(dir, root: payload)
      File.delete(File.join(dir, 'scripts', 'eohunter', 'watch.rb'))
      File.write(File.join(dir, 'scripts', 'eohunter.lic'), 'edited')
      state = described_class.check(dir)
      expect(state).to include(version: '1.0.0', missing: ['eohunter/watch.rb'], changed: ['eohunter.lic'])
      expect(described_class.check(lich('Empty'))).to be_nil
    end
  end

  describe '.lich_supported?' do
    it 'compares Lich\'s version with the script\'s requirement' do
      root = payload
      expect(described_class.lich_supported?(lich('New', version: '5.22.0'), root)).to be(true)
      expect(described_class.lich_supported?(lich('Old', version: '5.21.0'), root)).to be(false)
      expect(described_class.lich_supported?(lich('Unknown', version: nil), root)).to be_nil
    end
  end

  describe 'the eohunter command' do
    def run(*args)
      Open3.capture3(RbConfig.ruby, File.expand_path('../exe/eohunter', __dir__), *args)
    end

    it 'installs into a named Lich and warns when that Lich is too old' do
      dir = lich(version: '5.21.0')
      out, err, status = run('install', '--lich-dir', dir)
      expect(status).to be_success
      expect(out).to include('installed eohunter')
      expect(err).to include('needs 5.22.0 or later')
      expect(File).to exist(File.join(dir, 'scripts', 'eohunter.lic'))
      out, = run('doctor', '--lich-dir', dir)
      expect(out).to include('too old', "install: eohunter #{described_class.version}")
      _, _, status = run('uninstall', '--lich-dir', dir)
      expect(status).to be_success
      expect(File).not_to exist(File.join(dir, 'scripts', 'eohunter.lic'))
    end

    it 'says what is wrong and exits non-zero on a bad Lich directory' do
      _, err, status = run('install', '--lich-dir', @directory)
      expect(status).not_to be_success
      expect(err).to include('not a Lich install')
    end
  end
end
