#!/usr/bin/env ruby

require "json"
require "optparse"
require "pathname"

options = { root: Dir.pwd }
OptionParser.new do |parser|
  parser.on("--root PATH") { |path| options[:root] = path }
end.parse!

spec = JSON.parse(STDIN.read)

PLATFORM_ATTRIBUTE_KEYS = %w[ios macos osx tvos visionos watchos].freeze
PATH_ATTRIBUTE_KEYS = %w[
  project_header_files
  public_header_files
  private_header_files
  preserve_paths
  resource_bundles
  resources
  source_files
].freeze
FORBIDDEN_CHILD_KEYS = %w[appspecs].freeze
FORBIDDEN_COMPILATION_KEYS = %w[
  compiler_flags
  header_mappings_dir
  module_map
  on_demand_resources
  prefix_header_contents
  prefix_header_file
  user_target_xcconfig
  xcconfig
].freeze
FORBIDDEN_EXECUTION_KEYS = %w[prepare_command script_phase script_phases].freeze
FORBIDDEN_VENDOR_KEYS = %w[vendored_frameworks vendored_libraries].freeze
ALLOWED_POD_TARGET_XCCONFIG = {
  "DEFINES_MODULE" => "YES",
  "SWIFT_STRICT_CONCURRENCY" => "complete",
  "SWIFT_TREAT_WARNINGS_AS_ERRORS" => "YES",
}.freeze
ROOT_ALLOWED_KEYS = (
  %w[
    authors
    default_subspecs
    description
    homepage
    license
    module_name
    name
    platforms
    pod_target_xcconfig
    source
    subspecs
    summary
    swift_version
    swift_versions
    testspecs
    version
  ] + PATH_ATTRIBUTE_KEYS + PLATFORM_ATTRIBUTE_KEYS
).freeze
SUBSPEC_ALLOWED_KEYS = (
  %w[dependencies frameworks name pod_target_xcconfig subspecs] +
  PATH_ATTRIBUTE_KEYS +
  PLATFORM_ATTRIBUTE_KEYS
).freeze
TESTSPEC_ALLOWED_KEYS = (
  %w[dependencies name pod_target_xcconfig test_type] +
  PATH_ATTRIBUTE_KEYS +
  PLATFORM_ATTRIBUTE_KEYS
).freeze
PLATFORM_ALLOWED_KEYS = (
  %w[dependencies pod_target_xcconfig] + PATH_ATTRIBUTE_KEYS
).freeze

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

def expand_braces(pattern, limit = 256)
  results = [pattern]

  loop do
    expanded = false
    next_results = []

    results.each do |value|
      opening = value.index("{")
      unless opening
        next_results << value
        next
      end

      depth = 0
      closing = nil
      value.chars.each_with_index do |character, index|
        next if index < opening
        depth += 1 if character == "{"
        depth -= 1 if character == "}"
        if depth.zero?
          closing = index
          break
        end
      end
      abort "Unbalanced source glob braces: #{pattern}" unless closing

      content = value[(opening + 1)...closing]
      alternatives = []
      current = +""
      nested_depth = 0
      content.each_char do |character|
        nested_depth += 1 if character == "{"
        nested_depth -= 1 if character == "}"
        if character == "," && nested_depth.zero?
          alternatives << current
          current = +""
        else
          current << character
        end
      end
      alternatives << current

      prefix = value[0...opening]
      suffix = value[(closing + 1)..]
      alternatives.each { |alternative| next_results << "#{prefix}#{alternative}#{suffix}" }
      expanded = true
    end

    abort "Source glob brace expansion exceeds #{limit} alternatives." if next_results.length > limit
    results = next_results
    break unless expanded
  end

  results
end

def internal_dependency?(name, root_name)
  name == root_name || name.start_with?("#{root_name}/")
end

def validate_path_pattern(pattern, attribute, name, short_name, repository_root, roots)
  expected_root_name = short_name == "Core" ? "Core" : "SDK"
  authorized_root = roots.fetch(expected_root_name)

  expand_braces(pattern).each do |expanded_pattern|
    pathname = Pathname.new(expanded_pattern)
    abort "Absolute #{attribute} path in #{name}: #{pattern}" if pathname.absolute?
    abort "#{attribute} path traversal in #{name}: #{pattern}" if pathname.each_filename.include?("..")

    clean_pattern = pathname.cleanpath.to_s
    expected_prefix = "#{expected_root_name}/"
    abort "Unauthorized #{attribute} path in #{name}: #{pattern}" unless clean_pattern.start_with?(expected_prefix)

    Dir.chdir(repository_root) do
      Dir.glob(expanded_pattern, File::FNM_EXTGLOB).each do |match|
        candidate = repository_root.join(match)
        next unless candidate.exist?

        candidate_realpath = candidate.realpath.to_s
        contained = candidate_realpath == authorized_root.to_s ||
          candidate_realpath.start_with?("#{authorized_root}/")
        abort "#{attribute} path escapes #{expected_root_name} in #{name}: #{pattern}" unless contained
      end
    end
  end
end

def path_values(value)
  case value
  when String
    [value]
  when Array
    value.flat_map { |entry| path_values(entry) }
  when Hash
    value.values.flat_map { |entry| path_values(entry) }
  else
    []
  end
end

def present_attribute?(value)
  !value.nil? && (!value.respond_to?(:empty?) || !value.empty?)
end

def validate_attributes(attributes, root_name, name, short_name, repository_root, roots, scope)
  allowed_keys = case scope
                 when :root then ROOT_ALLOWED_KEYS
                 when :subspec then SUBSPEC_ALLOWED_KEYS
                 when :platform then PLATFORM_ALLOWED_KEYS
                 when :testspec then TESTSPEC_ALLOWED_KEYS
                 else abort "Unknown CocoaPods attribute scope: #{scope}"
                 end
  unexpected_keys = attributes.keys - allowed_keys
  abort "Unsupported CocoaPods attributes in #{name}: #{unexpected_keys.join(", ")}" unless unexpected_keys.empty?

  if scope == :testspec && attributes.fetch("test_type", "unit") != "unit"
    abort "Only unit CocoaPods test specifications are allowed in #{name}."
  end

  dependencies = attributes.fetch("dependencies", {}).keys
  external = dependencies.reject { |dependency| internal_dependency?(dependency, root_name) }
  abort "External dependency in #{name}: #{external.join(", ")}" unless external.empty?

  frameworks = Array(attributes["frameworks"])
  expected_frameworks = short_name == "SDK" ? ["Security"] : []
  abort "Unsupported Apple framework set in #{name}: #{frameworks.join(", ")}" unless frameworks == expected_frameworks

  FORBIDDEN_VENDOR_KEYS.each do |key|
    value = attributes[key]
    abort "Vendored binary attribute #{key} is forbidden in #{name}." if present_attribute?(value)
  end

  FORBIDDEN_EXECUTION_KEYS.each do |key|
    value = attributes[key]
    abort "Executable CocoaPods attribute #{key} is forbidden in #{name}." if present_attribute?(value)
  end

  FORBIDDEN_COMPILATION_KEYS.each do |key|
    value = attributes[key]
    abort "Custom compilation attribute #{key} is forbidden in #{name}." if present_attribute?(value)
  end

  FORBIDDEN_CHILD_KEYS.each do |key|
    value = attributes[key]
    abort "Unsupported CocoaPods child specification #{key} is forbidden in #{name}." if present_attribute?(value)
  end

  pod_target_xcconfig = attributes["pod_target_xcconfig"]
  if present_attribute?(pod_target_xcconfig)
    abort "pod_target_xcconfig must be a dictionary in #{name}." unless pod_target_xcconfig.is_a?(Hash)

    unexpected_keys = pod_target_xcconfig.keys - ALLOWED_POD_TARGET_XCCONFIG.keys
    abort "Unsupported pod_target_xcconfig keys in #{name}: #{unexpected_keys.join(", ")}" unless unexpected_keys.empty?

    pod_target_xcconfig.each do |key, value|
      expected_value = ALLOWED_POD_TARGET_XCCONFIG.fetch(key)
      abort "Unsupported pod_target_xcconfig value for #{key} in #{name}." unless value == expected_value
    end
  end

  PATH_ATTRIBUTE_KEYS.each do |key|
    path_values(attributes[key]).each do |pattern|
      validate_path_pattern(pattern, key, name, short_name, repository_root, roots)
    end
  end

  PLATFORM_ATTRIBUTE_KEYS.each do |platform|
    platform_attributes = attributes[platform]
    next unless platform_attributes.is_a?(Hash)

    validate_attributes(
      platform_attributes,
      root_name,
      "#{name}.#{platform}",
      short_name,
      repository_root,
      roots,
      :platform
    )
  end
end

def validate_spec(spec, root_name, repository_root, roots, inherited_path = root_name)
  name = spec.fetch("name", inherited_path)
  short_name = name.split("/").last
  scope = name == root_name ? :root : :subspec
  validate_attributes(spec, root_name, name, short_name, repository_root, roots, scope)

  Array(spec["subspecs"]).each do |subspec|
    validate_spec(subspec, root_name, repository_root, roots, name)
  end
  Array(spec["testspecs"]).each do |testspec|
    test_name = testspec.fetch("name", "#{name}/PublicAPI")
    abort "Only the PublicAPI CocoaPods test specification is allowed." unless test_name.split("/").last == "PublicAPI"
    validate_attributes(
      testspec,
      root_name,
      test_name,
      "PublicAPI",
      repository_root,
      roots,
      :testspec
    )
  end
end

root_name = spec.fetch("name")
repository_root, roots = authorized_roots(options.fetch(:root))
validate_spec(spec, root_name, repository_root, roots)

puts "CocoaPods dependency and source boundaries passed."
