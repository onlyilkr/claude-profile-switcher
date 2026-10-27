import Foundation

/// The interface speaks Turkish when that is the user's first language, English otherwise.
/// Pairs sit next to each other at the call site, so a missing translation cannot happen.
public enum Lang {
    public static var turkish: Bool = Locale.preferredLanguages.first?.lowercased().hasPrefix("tr") ?? false
}

public func L(_ en: String, _ tr: String) -> String { Lang.turkish ? tr : en }

public struct SwitcherError: LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
