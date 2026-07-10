version = File.read(File.join(__dir__, "VERSION")).strip

Pod::Spec.new do |spec|
  spec.name = "NearWire"
  spec.module_name = "NearWire"
  spec.version = version
  spec.summary = "A local bidirectional event platform for iOS applications and a macOS Viewer."
  spec.description = <<-DESC
    NearWire provides a Swift event API for local communication between iOS applications and
    a native macOS Viewer. The SDK supports peer-to-peer-enabled discovery, bounded delivery,
    optional connection UI, and optional built-in performance collection.
  DESC
  spec.homepage = "https://example.invalid/nearwire"
  spec.license = {
    :type => "Proprietary",
    :file => "LICENSE"
  }
  spec.authors = { "NearWire Team" => "nearwire@example.invalid" }
  spec.source = {
    :git => "https://example.invalid/nearwire.git",
    :tag => spec.version.to_s
  }

  spec.ios.deployment_target = "16.0"
  spec.swift_version = "5.0"
  spec.default_subspecs = "SDK"
  spec.pod_target_xcconfig = {
    "DEFINES_MODULE" => "YES",
    "SWIFT_STRICT_CONCURRENCY" => "complete",
    "SWIFT_TREAT_WARNINGS_AS_ERRORS" => "YES"
  }

  spec.subspec "Core" do |core|
    core.source_files = [
      "Core/Sources/NearWireCore/**/*.swift",
      "Core/Sources/NearWireTransport/**/*.swift",
      "Core/Sources/NearWireFlowControl/**/*.swift"
    ]
  end

  spec.subspec "SDK" do |sdk|
    sdk.dependency "NearWire/Core"
    sdk.source_files = "SDK/Sources/NearWire/**/*.swift"
  end

  spec.subspec "UI" do |ui|
    ui.dependency "NearWire/SDK"
    ui.source_files = "SDK/Sources/NearWireUI/**/*.swift"
  end

  spec.subspec "Performance" do |performance|
    performance.dependency "NearWire/SDK"
    performance.source_files = "SDK/Sources/NearWirePerformance/**/*.swift"
  end
end
