# frozen_string_literal: true

require_relative 'lib/eohunter/install'

Gem::Specification.new do |spec|
  spec.name = 'eohunter'
  spec.version = EOHunter::Install.version
  spec.authors = ['Elanthia Online']
  spec.summary = 'A hunting script for Gemstone IV on Lich 5, and its installer'
  spec.description = <<~TEXT
    eohunter hunts with an engine of small behaviors, reads Bigshot profiles
    unchanged, and has a GTK hunt editor. This gem carries the scripts and an
    installer: `eohunter install` copies them into a Lich install.
  TEXT
  spec.homepage = 'https://github.com/elanthia-online/eohunter'
  spec.metadata = {
    'source_code_uri'       => spec.homepage,
    'documentation_uri'     => 'https://elanthia-online.github.io/eohunter/',
    'rubygems_mfa_required' => 'true'
  }
  # The installer is plain Ruby; any current Ruby runs it, not only Lich's.
  spec.required_ruby_version = '>= 3.0' # rubocop:disable Gemspec/RequiredRubyVersion

  spec.files = Dir['lib/**/*.rb', 'exe/*', 'README.md'] +
               EOHunter::Install.payload_files(File.join(__dir__, 'scripts')).map { |rel| "scripts/#{rel}" }
  spec.bindir = 'exe'
  spec.executables = ['eohunter']
  spec.require_paths = ['lib']
end
