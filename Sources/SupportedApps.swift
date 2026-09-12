import Foundation

/// Shared by the app and launch helper. Store stable IDs, never localized names.
enum SupportedApp: String, CaseIterable {
    case orca, chatgpt, cursor
    var name: String {
        switch self { case .orca: return "Orca"; case .chatgpt: return "ChatGPT"; case .cursor: return "Cursor" }
    }
    var bundleIdentifiers: [String] {
        switch self {
        case .orca: return ["com.stablyai.orca"]
        case .chatgpt: return ["com.openai.codex"] // The desktop app containing ChatGPT and Codex modes.
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        }
    }
    static func identify(_ bundle: String?) -> SupportedApp? {
        guard let bundle else { return nil }
        return allCases.first { $0.bundleIdentifiers.contains(bundle) }
    }
    static func enabled(in defaults: UserDefaults = .standard) -> Set<SupportedApp> {
        guard let values = defaults.stringArray(forKey: "supportedApps") else { return [.orca] }
        return Set(values.compactMap(Self.init(rawValue:)))
    }
    static func accepts(_ bundle: String?, defaults: UserDefaults = .standard) -> Bool {
        identify(bundle).map { enabled(in: defaults).contains($0) } ?? false
    }
    static func save(_ apps: Set<SupportedApp>, in defaults: UserDefaults = .standard) {
        defaults.set(allCases.filter { apps.contains($0) }.map(\.rawValue), forKey: "supportedApps")
    }
}
