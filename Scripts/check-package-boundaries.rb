#!/usr/bin/env ruby

require "json"
require "optparse"
require "pathname"

options = { root: Dir.pwd }
OptionParser.new do |parser|
  parser.on("--root PATH") { |path| options[:root] = path }
end.parse!

package = JSON.parse(STDIN.read)
dependencies = package.fetch("dependencies")
abort "Root Package.swift must not contain external dependencies." unless dependencies.empty?

def authorized_roots(root)
  repository_root = Pathname.new(root).realpath
  roots = %w[Core SDK].to_h do |name|
    lexical_root = repository_root.join(name)
    abort "Ownership root must be a real directory: #{name}" unless lexical_root.directory?
    abort "Ownership root must not be a symlink: #{name}" if lexical_root.symlink?

    real_root = lexical_root.realpath
    abort "Ownership root must be directly below the repository root: #{name}" unless real_root.parent == repository_root
    [name, real_root]
  end
  abort "Core and SDK ownership roots must be distinct." if roots.fetch("Core") == roots.fetch("SDK")

  [repository_root, roots]
end

def contained_path?(repository_root, roots, path)
  pathname = Pathname.new(path)
  return false if pathname.absolute?
  return false if pathname.each_filename.include?("..")

  clean = pathname.cleanpath.to_s
  ownership_root_name = clean.split("/").first
  return false unless %w[Core SDK].include?(ownership_root_name)
  return false if clean == ownership_root_name

  ownership_root = roots.fetch(ownership_root_name)
  candidate = repository_root.join(clean)
  return false unless candidate.exist?

  candidate_realpath = candidate.realpath.to_s
  candidate_realpath == ownership_root.to_s ||
    candidate_realpath.start_with?("#{ownership_root}/")
end

repository_root, roots = authorized_roots(options.fetch(:root))

package.fetch("targets").each do |target|
  type = target.fetch("type")
  unless %w[regular test].include?(type)
    abort "Unauthorized root package target type in #{target.fetch("name")}: #{type}"
  end

  path = target["path"]
  abort "Root package target must declare an explicit path: #{target.fetch("name")}" if path.nil?

  abort "Unauthorized root package target path: #{path}" unless contained_path?(repository_root, roots, path)
end

puts "Swift Package dependency and path boundaries passed."
