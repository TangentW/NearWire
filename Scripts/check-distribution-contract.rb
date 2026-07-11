#!/usr/bin/env ruby

require "json"
require "optparse"

module NearWireDistributionContract
  class ContractError < StandardError; end

  EXPECTED_PRODUCTS = {
    "NearWire" => ["NearWire"],
    "NearWireCore" => %w[NearWireCore NearWireTransport NearWireFlowControl],
    "NearWirePerformance" => ["NearWirePerformance"],
    "NearWireUI" => ["NearWireUI"],
  }.freeze

  EXPECTED_PACKAGE_TARGETS = {
    "NearWireCore" => ["regular", "Core/Sources/NearWireCore", []],
    "NearWireTransport" => ["regular", "Core/Sources/NearWireTransport", ["NearWireCore"]],
    "NearWireFlowControl" => ["regular", "Core/Sources/NearWireFlowControl", ["NearWireCore"]],
    "NearWire" => ["regular", "SDK/Sources/NearWire", %w[NearWireCore NearWireTransport NearWireFlowControl]],
    "NearWireUI" => ["regular", "SDK/Sources/NearWireUI", ["NearWire"]],
    "NearWirePerformance" => ["regular", "SDK/Sources/NearWirePerformance", %w[NearWire NearWireCore]],
    "NearWireTestSupport" => ["regular", "Core/TestSupport/NearWireTestSupport", %w[NearWireCore NearWireTransport NearWireFlowControl]],
    "NearWireCoreTests" => ["test", "Core/Tests/NearWireCoreTests", ["NearWireCore"]],
    "NearWireTransportTests" => ["test", "Core/Tests/NearWireTransportTests", ["NearWireTransport"]],
    "NearWireFlowControlTests" => ["test", "Core/Tests/NearWireFlowControlTests", ["NearWireFlowControl"]],
    "NearWireTestSupportTests" => ["test", "Core/Tests/NearWireTestSupportTests", ["NearWireTestSupport"]],
    "NearWireTests" => ["test", "SDK/Tests/NearWireTests", %w[NearWire NearWireTransport]],
    "NearWireUITests" => ["test", "SDK/Tests/NearWireUITests", ["NearWireUI"]],
    "NearWirePerformanceTests" => ["test", "SDK/Tests/NearWirePerformanceTests", ["NearWirePerformance"]],
  }.freeze

  EXPECTED_POD_SUBSPECS = {
    "Core" => {
      "dependencies" => [],
      "source_files" => [
        "Core/Sources/NearWireCore/**/*.swift",
        "Core/Sources/NearWireTransport/**/*.swift",
        "Core/Sources/NearWireFlowControl/**/*.swift",
      ],
    },
    "SDK" => {
      "dependencies" => ["NearWire/Core"],
      "source_files" => ["SDK/Sources/NearWire/**/*.swift"],
    },
    "UI" => {
      "dependencies" => ["NearWire/SDK"],
      "source_files" => ["SDK/Sources/NearWireUI/**/*.swift"],
    },
    "Performance" => {
      "dependencies" => ["NearWire/SDK"],
      "source_files" => ["SDK/Sources/NearWirePerformance/**/*.swift"],
    },
  }.freeze
  EXPECTED_POD_XCCONFIG = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_STRICT_CONCURRENCY" => "complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS" => "YES",
  }.freeze
  EXPECTED_POD_TESTSPECS = {
    "PublicAPI" => {
      "name" => "PublicAPI",
      "source_files" => ["SDK/Tests/PublicAPIConsumer/**/*.swift"],
      "test_type" => "unit",
    },
  }.freeze

  module_function

  def assert(condition, message)
    raise ContractError, message unless condition
  end

  def expected_product_descriptors
    EXPECTED_PRODUCTS.to_h do |name, targets|
      [
        name,
        {
          "name" => name,
          "settings" => [],
          "targets" => targets,
          "type" => { "library" => ["automatic"] },
        },
      ]
    end
  end

  def expected_target_descriptors
    EXPECTED_PACKAGE_TARGETS.to_h do |name, (type, path, dependencies)|
      [
        name,
        {
          "dependencies" => dependencies.map { |dependency| { "byName" => [dependency, nil] } },
          "exclude" => [],
          "name" => name,
          "packageAccess" => true,
          "path" => path,
          "resources" => [],
          "settings" => [],
          "type" => type,
        },
      ]
    end
  end

  def validate_package(package)
    assert(package["name"] == "NearWire", "Swift Package name must be NearWire.")
    assert(package.dig("toolsVersion", "_version") == "5.9.0", "Swift tools version must be 5.9.0.")
    assert(package["swiftLanguageVersions"] == ["5"], "Swift Package must use Swift 5 language mode.")

    platforms = package.fetch("platforms").to_h do |platform|
      [platform.fetch("platformName"), platform.fetch("version")]
    end
    assert(platforms == { "ios" => "16.0", "macos" => "13.0" }, "Swift Package platforms must be iOS 16 and macOS 13.")

    products = package.fetch("products").to_h { |product| [product.fetch("name"), product] }
    assert(products == expected_product_descriptors, "Swift Package product descriptors changed.")

    targets = package.fetch("targets").to_h { |target| [target.fetch("name"), target] }
    assert(targets == expected_target_descriptors, "Swift Package target descriptors changed.")
  end

  def validate_podspec(spec)
    assert(spec["name"] == "NearWire", "Pod name must be NearWire.")
    assert(spec["module_name"] == "NearWire", "Pod module name must be NearWire.")
    assert(spec["homepage"] == "https://example.invalid/nearwire", "Pod homepage must use the reserved bootstrap URL.")
    assert(spec["authors"] == { "NearWire Team" => "nearwire@example.invalid" }, "Pod author identity changed.")
    assert(spec["license"] == { "type" => "Proprietary", "file" => "LICENSE" }, "Pod license metadata changed.")
    expected_source = {
      "git" => "https://example.invalid/nearwire.git",
      "tag" => spec.fetch("version"),
    }
    assert(spec["source"] == expected_source, "Pod source must use the reserved Git URL and product-version tag only.")
    assert(spec["platforms"] == { "ios" => "16.0" }, "Pod platform must be iOS 16.")
    assert(spec["swift_version"] == "5.0", "Pod Swift version must be 5.0.")
    assert(Array(spec["swift_versions"]) == ["5.0"], "Pod Swift versions must contain only 5.0.")
    assert(Array(spec["default_subspecs"]) == ["SDK"], "SDK must be the sole default pod subspec.")
    assert(spec["pod_target_xcconfig"] == EXPECTED_POD_XCCONFIG, "Pod target build settings changed.")

    root_forbidden_mappings = %w[
      ios macos osx tvos visionos watchos
      source_files resources resource_bundles
      project_header_files public_header_files private_header_files preserve_paths
    ]
    present_root_mappings = root_forbidden_mappings.select { |key| spec.key?(key) }
    assert(present_root_mappings.empty?, "Unapproved root or platform pod mappings changed: #{present_root_mappings.join(", ")}.")

    subspecs = Array(spec["subspecs"]).to_h do |subspec|
      name = subspec.fetch("name").split("/").last
      normalized = deep_copy(subspec)
      normalized["name"] = name
      normalized["dependencies"] = normalized.fetch("dependencies", {})
      normalized["source_files"] = Array(normalized["source_files"])
      [name, normalized]
    end
    expected_subspecs = EXPECTED_POD_SUBSPECS.to_h do |name, details|
      normalized = {
        "name" => name,
        "dependencies" => details.fetch("dependencies").to_h { |dependency| [dependency, []] },
        "source_files" => details.fetch("source_files"),
      }
      [name, normalized]
    end
    assert(subspecs == expected_subspecs, "Pod subspec graph or source mappings changed.")

    testspecs = Array(spec["testspecs"]).to_h do |testspec|
      name = testspec.fetch("name").split("/").last
      normalized = deep_copy(testspec)
      normalized["name"] = name
      normalized["source_files"] = Array(normalized["source_files"])
      normalized["test_type"] = normalized.fetch("test_type", "unit")
      [name, normalized]
    end
    assert(testspecs == EXPECTED_POD_TESTSPECS, "Pod public API test specification changed.")
  end

  def valid_package_fixture
    {
      "name" => "NearWire",
      "toolsVersion" => { "_version" => "5.9.0" },
      "swiftLanguageVersions" => ["5"],
      "platforms" => [
        { "platformName" => "ios", "version" => "16.0" },
        { "platformName" => "macos", "version" => "13.0" },
      ],
      "products" => EXPECTED_PRODUCTS.map do |name, targets|
        {
          "name" => name,
          "settings" => [],
          "targets" => targets,
          "type" => { "library" => ["automatic"] },
        }
      end,
      "targets" => expected_target_descriptors.values,
    }
  end

  def valid_podspec_fixture
    {
      "name" => "NearWire",
      "version" => "0.1.0",
      "module_name" => "NearWire",
      "homepage" => "https://example.invalid/nearwire",
      "authors" => { "NearWire Team" => "nearwire@example.invalid" },
      "license" => { "type" => "Proprietary", "file" => "LICENSE" },
      "source" => { "git" => "https://example.invalid/nearwire.git", "tag" => "0.1.0" },
      "platforms" => { "ios" => "16.0" },
      "swift_version" => "5.0",
      "swift_versions" => "5.0",
      "default_subspecs" => "SDK",
      "pod_target_xcconfig" => EXPECTED_POD_XCCONFIG,
      "subspecs" => EXPECTED_POD_SUBSPECS.map do |name, details|
        {
          "name" => name,
          "dependencies" => details.fetch("dependencies").to_h { |dependency| [dependency, []] },
          "source_files" => details.fetch("source_files"),
        }
      end,
      "testspecs" => EXPECTED_POD_TESTSPECS.values,
    }
  end

  def deep_copy(value)
    JSON.parse(JSON.generate(value))
  end

  def expect_failure(label)
    begin
      yield
    rescue ContractError
      return
    end

    raise ContractError, "Mutation unexpectedly passed: #{label}"
  end

  def self_test
    validate_package(valid_package_fixture)
    validate_podspec(valid_podspec_fixture)

    package_mutations = {
      "package name" => ->(value) { value["name"] = "Other" },
      "tools version" => ->(value) { value["toolsVersion"]["_version"] = "6.0.0" },
      "Swift language" => ->(value) { value["swiftLanguageVersions"] = ["6"] },
      "iOS platform" => ->(value) { value["platforms"][0]["version"] = "17.0" },
      "missing product" => ->(value) { value["products"].shift },
      "product membership" => ->(value) { value["products"][0]["targets"] = ["NearWireCore"] },
      "dynamic product" => ->(value) { value["products"][0]["type"] = { "library" => ["dynamic"] } },
      "static product" => ->(value) { value["products"][0]["type"] = { "library" => ["static"] } },
      "conditional dependency" => ->(value) { value["targets"][1]["dependencies"][0]["byName"][1] = { "platformNames" => ["ios"] } },
      "unsafe Swift flags" => ->(value) { value["targets"][0]["settings"] = [{ "kind" => { "unsafeFlags" => { "_0" => ["-DATTACK"] } }, "tool" => "swift" }] },
      "unsafe C flags" => ->(value) { value["targets"][0]["settings"] = [{ "kind" => { "unsafeFlags" => { "_0" => ["-DATTACK"] } }, "tool" => "c" }] },
      "unsafe linker flags" => ->(value) { value["targets"][0]["settings"] = [{ "kind" => { "unsafeFlags" => { "_0" => ["-load", "plugin"] } }, "tool" => "linker" }] },
      "plugin usage" => ->(value) { value["targets"][0]["pluginUsages"] = [{ "plugin" => ["AttackPlugin", nil] }] },
      "target resources" => ->(value) { value["targets"][0]["resources"] = [{ "rule" => "process", "path" => "Payload" }] },
      "target exclusions" => ->(value) { value["targets"][0]["exclude"] = ["Hidden.swift"] },
    }
    package_mutations.each do |label, mutation|
      value = deep_copy(valid_package_fixture)
      mutation.call(value)
      expect_failure(label) { validate_package(value) }
    end

    pod_mutations = {
      "pod name" => ->(value) { value["name"] = "Other" },
      "module name" => ->(value) { value["module_name"] = "OtherWire" },
      "homepage drift" => ->(value) { value["homepage"] = "https://attacker.invalid" },
      "hostile Git" => ->(value) { value["source"]["git"] = "https://attacker.invalid/repo.git" },
      "HTTP archive" => ->(value) { value["source"] = { "http" => "https://attacker.invalid/archive.zip" } },
      "source branch" => ->(value) { value["source"]["branch"] = "main" },
      "source commit" => ->(value) { value["source"]["commit"] = "deadbeef" },
      "tag drift" => ->(value) { value["source"]["tag"] = "9.9.9" },
      "license file" => ->(value) { value["license"]["file"] = "OTHER-LICENSE" },
      "author identity" => ->(value) { value["authors"] = { "Unknown" => "unknown@example.invalid" } },
      "iOS deployment" => ->(value) { value["platforms"]["ios"] = "17.0" },
      "Swift version" => ->(value) { value["swift_version"] = "6.0" },
      "Swift versions" => ->(value) { value["swift_versions"] = "6.0" },
      "default subspec" => ->(value) { value["default_subspecs"] = ["SDK", "UI"] },
      "missing subspec" => ->(value) { value["subspecs"].pop },
      "missing public API testspec" => ->(value) { value["testspecs"].clear },
      "public API testspec source" => ->(value) { value["testspecs"][0]["source_files"] = ["SDK/Other/**/*.swift"] },
      "subspec dependency" => ->(value) { value["subspecs"][1]["dependencies"] = {} },
      "subspec dependency constraint" => ->(value) { value["subspecs"][1]["dependencies"]["NearWire/Core"] = ["~> 1.0"] },
      "subspec source" => ->(value) { value["subspecs"][1]["source_files"] = ["SDK/Other/**/*.swift"] },
      "root source" => ->(value) { value["source_files"] = ["SDK/Other/**/*.swift"] },
      "platform source" => ->(value) { value["subspecs"][1]["ios"] = { "source_files" => ["SDK/Other/**/*.swift"] } },
    }
    pod_mutations.each do |label, mutation|
      value = deep_copy(valid_podspec_fixture)
      mutation.call(value)
      expect_failure(label) { validate_podspec(value) }
    end

    puts "Distribution contract mutation tests passed."
  end
end

if __FILE__ == $PROGRAM_NAME
  options = {}
  OptionParser.new do |parser|
    parser.on("--package-json PATH") { |path| options[:package_json] = path }
    parser.on("--pod-json PATH") { |path| options[:pod_json] = path }
    parser.on("--self-test") { options[:self_test] = true }
  end.parse!

  begin
    if options[:self_test]
      NearWireDistributionContract.self_test
    else
      abort "Both --package-json and --pod-json are required." unless options[:package_json] && options[:pod_json]
      NearWireDistributionContract.validate_package(JSON.parse(File.read(options.fetch(:package_json))))
      NearWireDistributionContract.validate_podspec(JSON.parse(File.read(options.fetch(:pod_json))))
      puts "Distribution manifest contract passed."
    end
  rescue NearWireDistributionContract::ContractError => error
    warn error.message
    exit 1
  end
end
