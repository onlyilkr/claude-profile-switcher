import Foundation

/// The interface speaks Turkish when that is the user's first language, English otherwise.
/// Pairs sit next to each other at the call site, so a missing translation cannot happen.
public enum Lang {
    public static var turkish: Bool = Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") ?? false
}

public func L(_ en: String, _ tr: String) -> String { Lang.turkish ? tr : en }

public struct SwitcherError: LocalizedError, Equatable {
    public let message: String
    /// A fixed English reason without paths, names or ids, for logs; nil = log only the error's domain and code.
    public let logReason: String?
    /// Where something the user may need is (a backup folder). Never logged.
    public let detail: String?
    public init(_ message: String, logReason: String? = nil, detail: String? = nil) {
        self.message = message; self.logReason = logReason; self.detail = detail
    }
    public var errorDescription: String? { message }
}
