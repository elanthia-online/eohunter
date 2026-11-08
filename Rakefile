# frozen_string_literal: true

desc 'Build the eohunter gem into dist/'
task :gem do
  require 'fileutils'
  require 'rubygems/package'
  spec = Gem::Specification.load(File.join(__dir__, 'eohunter.gemspec'))
  FileUtils.mkdir_p(File.join(__dir__, 'dist'))
  Dir.chdir(__dir__) do
    file = Gem::Package.build(spec)
    FileUtils.mv(file, File.join('dist', file))
    puts "built dist/#{file} (#{spec.files.size} files)"
  end
end

desc 'Remove dist/'
task :clean do
  require 'fileutils'
  FileUtils.rm_rf(File.join(__dir__, 'dist'))
end

task default: :gem

begin
  require 'yard'
  YARD::Rake::YardocTask.new(:doc) do |t|
    t.options = [] # everything is in .yardopts
  end
  # The guides' markdown links, pointed at YARD's file.<name>.html pages.
  Rake::Task[:doc].enhance do
    require_relative 'tools/doclinks'
    changed = EOHunter::DocLinks.rewrite_dir('doc', names: EOHunter::DocLinks.names_from('.yardopts'))
    puts "doc links: #{changed} pages rewritten"
  end
  desc 'YARD coverage, listing what is undocumented'
  task 'doc:stats' do
    sh 'bundle exec yard stats --list-undoc'
  end
rescue LoadError
  desc 'YARD is not installed'
  task(:doc) { abort 'bundle install first: yard is missing' }
end
