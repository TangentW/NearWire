import Combine
import Foundation
import SwiftUI

enum ViewerLanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case system
  case english
  case simplifiedChinese

  var id: String { rawValue }

  var explicitLocale: Locale? {
    switch self {
    case .system:
      return nil
    case .english:
      return Locale(identifier: "en")
    case .simplifiedChinese:
      return Locale(identifier: "zh-Hans")
    }
  }
}

@MainActor
final class ViewerLanguageController: ObservableObject {
  static let defaultsKey = "viewer.language.preference"

  @Published private(set) var preference: ViewerLanguagePreference
  @Published private var systemLocaleRevision: UInt64 = 0

  private let defaults: UserDefaults
  private let systemLocaleProvider: () -> Locale
  private var normalizedSystemLocaleIdentifier: String

  init(
    defaults: UserDefaults = .standard,
    systemLocaleProvider: @escaping () -> Locale = ViewerLocalization.currentSystemLocale
  ) {
    self.defaults = defaults
    self.systemLocaleProvider = systemLocaleProvider
    normalizedSystemLocaleIdentifier = ViewerLocalization.localizationIdentifier(
      for: systemLocaleProvider()
    )
    let storedValue = defaults.object(forKey: Self.defaultsKey)
    if let rawValue = storedValue as? String,
      let storedPreference = ViewerLanguagePreference(rawValue: rawValue)
    {
      preference = storedPreference
    } else {
      preference = .system
      if storedValue != nil {
        defaults.set(ViewerLanguagePreference.system.rawValue, forKey: Self.defaultsKey)
      }
    }
  }

  var effectiveLocale: Locale {
    _ = systemLocaleRevision
    if let explicitLocale = preference.explicitLocale {
      return explicitLocale
    }
    return Locale(identifier: normalizedSystemLocaleIdentifier)
  }

  func select(_ newPreference: ViewerLanguagePreference) {
    guard preference != newPreference else { return }
    preference = newPreference
    defaults.set(newPreference.rawValue, forKey: Self.defaultsKey)
  }

  func refreshSystemLocale() {
    let updatedIdentifier = ViewerLocalization.localizationIdentifier(for: systemLocaleProvider())
    guard updatedIdentifier != normalizedSystemLocaleIdentifier else { return }
    normalizedSystemLocaleIdentifier = updatedIdentifier
    guard preference == .system else { return }
    systemLocaleRevision &+= 1
  }
}

enum ViewerLocalization {
  private static let mainLocalizedBundles: [String: Bundle] = {
    Dictionary(
      uniqueKeysWithValues: ["en", "zh-Hans"].compactMap { identifier in
        guard
          let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
          let bundle = Bundle(path: path)
        else {
          return nil
        }
        return (identifier, bundle)
      }
    )
  }()

  static func currentSystemLocale() -> Locale {
    Locale(identifier: Locale.preferredLanguages.first ?? "en")
  }

  static func localizationIdentifier(for locale: Locale) -> String {
    let identifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
    let components = identifier.split(separator: "-").map { $0.lowercased() }
    return components.first == "zh" ? "zh-Hans" : "en"
  }

  static func string(
    _ key: String,
    locale: Locale,
    bundle: Bundle = .main
  ) -> String {
    let identifier = localizationIdentifier(for: locale)
    let localizedBundle: Bundle?
    if bundle === Bundle.main {
      localizedBundle = mainLocalizedBundles[identifier]
    } else if let path = bundle.path(forResource: identifier, ofType: "lproj") {
      localizedBundle = Bundle(path: path)
    } else {
      localizedBundle = nil
    }
    guard let localizedBundle else { return key }
    return localizedBundle.localizedString(forKey: key, value: key, table: nil)
  }

  static func format(
    _ key: String,
    locale: Locale,
    arguments: [CVarArg],
    bundle: Bundle = .main
  ) -> String {
    String(
      format: string(key, locale: locale, bundle: bundle),
      locale: locale,
      arguments: arguments
    )
  }
}

struct ViewerLanguageSettingsView: View {
  @ObservedObject var controller: ViewerLanguageController

  var body: some View {
    Form {
      Picker(
        "Language",
        selection: Binding(
          get: { controller.preference },
          set: { controller.select($0) }
        )
      ) {
        Text("System").tag(ViewerLanguagePreference.system)
        Text(verbatim: "English").tag(ViewerLanguagePreference.english)
        Text(verbatim: "简体中文").tag(ViewerLanguagePreference.simplifiedChinese)
      }
      .pickerStyle(.radioGroup)
      .accessibilityLabel("Viewer language")

      Text(
        "System uses Simplified Chinese for any Chinese macOS language and English otherwise. Manual choices apply immediately to every NearWire window."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    }
    .formStyle(.grouped)
    .padding(12)
    .frame(width: 440, height: 240)
  }
}

extension View {
  func viewerLanguageEnvironment(_ controller: ViewerLanguageController) -> some View {
    environmentObject(controller)
      .environment(\.locale, controller.effectiveLocale)
      .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) {
        _ in
        controller.refreshSystemLocale()
      }
  }
}
