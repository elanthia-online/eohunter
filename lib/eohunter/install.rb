# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'json'

# The eohunter gem's installer: copies the scripts the gem carries into a
# Lich install, and takes them out again. Ordinary Ruby, never loaded by
# Lich; `exe/eohunter` is its command line.
module EOHunter
  # Install, upgrade, uninstall and report on eohunter in a Lich directory.
  #
  # What it copies is the gem's `scripts/` tree: the script, the engine and
  # setup parts, and the coordination library. What it installed is
  # recorded in a manifest beside the parts, so an upgrade removes a file a
  # newer version dropped and an uninstall removes exactly what was put
  # there. Player data under `data/` is never touched.
  module Install
    # The paths under `scripts/` that make up an install.
    PAYLOAD = %w[eohunter.lic eohunter libeocoordination.lic eocoordination].freeze

    # Where the manifest is kept, relative to Lich's `scripts/`.
    MANIFEST = File.join('eohunter', '.install-manifest.json')

    # Directory names a Lich install usually has, for #candidates.
    LICH_NAMES = %w[Lich5 lich5 Lich lich].freeze

    # Raised for anything the command line should report and stop on.
    class Error < StandardError; end

    module_function

    # @return [String] the `scripts/` directory this gem carries
    def payload_root = File.expand_path('../../scripts', __dir__)

    # Every file of the install, relative to `scripts/`.
    #
    # @param root [String] a `scripts/` directory
    # @return [Array<String>] relative paths, '/'-separated, sorted
    def payload_files(root = payload_root)
      PAYLOAD.flat_map do |entry|
        path = File.join(root, entry)
        next [entry] if File.file?(path)

        Dir.glob('**/*', base: path).select { |rel| File.file?(File.join(path, rel)) }.map { |rel| "#{entry}/#{rel}" }
      end.sort
    end

    # @param root [String] a `scripts/` directory
    # @return [String] the engine version it carries, from EO::Engine::VERSION
    def version(root = payload_root)
      source = File.read(File.join(root, 'eohunter', 'engine.rb'))
      source[/VERSION\s*=\s*'([^']+)'/, 1] or raise Error, 'cannot read EO::Engine::VERSION'
    end

    # @param root [String] a `scripts/` directory
    # @return [String] the Lich version eohunter.lic's header requires
    def required_lich(root = payload_root)
      header = File.read(File.join(root, 'eohunter.lic'))
      header[/required:\s*Lich\s*>=\s*([\d.]+)/, 1] or raise Error, 'cannot read the required Lich version'
    end

    # @param dir [String] a candidate Lich directory
    # @return [Boolean] whether it looks like a Lich install
    def lich?(dir)
      File.file?(File.join(dir, 'lich.rbw')) && File.directory?(File.join(dir, 'scripts'))
    end

    # @param dir [String] a Lich directory
    # @return [String, nil] its LICH_VERSION, or nil when it cannot be read
    def lich_version(dir)
      path = File.join(dir, 'lib', 'version.rb')
      File.file?(path) ? File.read(path)[/LICH_VERSION\s*=\s*'([^']+)'/, 1] : nil
    end

    # @param dir [String] a Lich directory
    # @param root [String] a `scripts/` directory
    # @return [Boolean, nil] whether its Lich is new enough; nil when unknown
    def lich_supported?(dir, root = payload_root)
      found = lich_version(dir)
      found && Gem::Version.new(found) >= Gem::Version.new(required_lich(root))
    end

    # Places a Lich install is usually found, in the order they are tried.
    #
    # @param home [String] the user's home directory
    # @param drives [Array<String>] drive roots to look under (Windows)
    # @return [Array<String>]
    def candidates(home: Dir.home, drives: windows_drives)
      roots = [home, File.join(home, 'Documents'), File.join(home, 'Desktop')] + drives
      roots.product(LICH_NAMES).map { |(root, name)| File.join(root, name) }.uniq
    end

    # @return [Array<String>] the drive roots that exist, C: to Z:, on Windows
    def windows_drives
      return [] unless Gem.win_platform?

      ('C'..'Z').map { |letter| "#{letter}:/" }.select { |root| File.directory?(root) }
    end

    # The Lich directory to install into.
    #
    # @param explicit [String, nil] --lich-dir, which must be a Lich install
    # @param env [String, nil] LICH_DIR, likewise
    # @param candidates [Array<String>] places to look otherwise
    # @return [String] the directory
    # @raise [Error] when none is found, or several are and none was named
    def find_lich(explicit: nil, env: ENV.fetch('LICH_DIR', nil), candidates: self.candidates)
      [[explicit, '--lich-dir'], [env, 'LICH_DIR']].each do |(dir, source)|
        next if dir.nil? || dir.empty?
        raise Error, "#{source} #{dir} is not a Lich install (no lich.rbw and scripts/)" unless lich?(dir)

        return File.expand_path(dir)
      end
      found = candidates.select { |dir| lich?(dir) }.map { |dir| File.expand_path(dir) }.uniq
      return found.first if found.size == 1
      raise Error, 'no Lich install found; name it with --lich-dir <path>' if found.empty?

      raise Error, "several Lich installs found (#{found.join(', ')}); name one with --lich-dir <path>"
    end

    # @param lich_dir [String] a Lich directory
    # @return [Hash, nil] the manifest of what is installed there
    def manifest(lich_dir)
      path = File.join(lich_dir, 'scripts', MANIFEST)
      File.file?(path) ? JSON.parse(File.read(path)) : nil
    end

    # Copy the gem's scripts into Lich, replacing an earlier install.
    #
    # @param lich_dir [String] a Lich directory
    # @param root [String] a `scripts/` directory to install from
    # @return [Hash] :version, :copied and :removed (relative paths)
    def install(lich_dir, root: payload_root)
      raise Error, "#{lich_dir} is not a Lich install" unless lich?(lich_dir)

      scripts = File.join(lich_dir, 'scripts')
      files = payload_files(root)
      stale = (manifest(lich_dir)&.fetch('files', {})&.keys || []) - files
      stale.each { |rel| FileUtils.rm_f(File.join(scripts, rel)) }
      digests = files.to_h do |rel|
        target = File.join(scripts, rel)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(File.join(root, rel), target)
        [rel, Digest::SHA256.file(target).hexdigest]
      end
      prune(scripts, stale)
      record = { 'version' => version(root), 'files' => digests }
      File.write(File.join(scripts, MANIFEST), JSON.pretty_generate(record))
      { version: record['version'], copied: files, removed: stale }
    end

    # Remove exactly what the manifest says was installed.
    #
    # @param lich_dir [String] a Lich directory
    # @return [Array<String>] the relative paths removed
    # @raise [Error] when nothing was installed by this gem
    def uninstall(lich_dir)
      record = manifest(lich_dir) or raise Error, "no eohunter install recorded in #{lich_dir}"
      scripts = File.join(lich_dir, 'scripts')
      files = record.fetch('files').keys
      files.each { |rel| FileUtils.rm_f(File.join(scripts, rel)) }
      FileUtils.rm_f(File.join(scripts, MANIFEST))
      prune(scripts, files)
      files
    end

    # What is installed, and whether the files are still as installed.
    #
    # @param lich_dir [String] a Lich directory
    # @return [Hash] :version, :missing and :changed (relative paths), or
    #   nil when nothing is recorded
    def check(lich_dir)
      record = manifest(lich_dir) or return nil
      scripts = File.join(lich_dir, 'scripts')
      missing, present = record.fetch('files').partition { |(rel, _)| !File.file?(File.join(scripts, rel)) }
      changed = present.reject { |(rel, digest)| Digest::SHA256.file(File.join(scripts, rel)).hexdigest == digest }
      { version: record['version'], missing: missing.map(&:first), changed: changed.map(&:first) }
    end

    # Remove directories the install left empty, deepest first. Only
    # directories that held an installed file are considered.
    def prune(scripts, rels)
      dirs = rels.flat_map do |rel|
        parts = File.dirname(rel).split('/')
        (1..parts.size).map { |n| parts.first(n).join('/') }
      end
      dirs.uniq.reject { |dir| dir == '.' }.sort_by { |dir| -dir.count('/') }.each do |dir|
        path = File.join(scripts, dir)
        Dir.rmdir(path) if File.directory?(path) && Dir.empty?(path)
      end
    end
  end
end
