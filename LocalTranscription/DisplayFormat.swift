import Foundation
import Voz

/// Human-readable times and language names for the status bar, Recording Info, and History.
enum DisplayFormat {
    /// Recording lengths: “5.8 s” under a minute, otherwise “11m 28s” or “2h 2m 5s”.
    static func duration(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        guard seconds >= 60 else {
            return seconds.formatted(.number.precision(.fractionLength(1)).locale(locale)) + " s"
        }
        return Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow).locale(locale))
    }

    /// Processing times, which are usually a second or less, so they keep two decimals.
    static func processingTime(_ seconds: TimeInterval, locale: Locale = .current) -> String {
        guard seconds >= 60 else {
            return seconds.formatted(.number.precision(.fractionLength(2)).locale(locale)) + " s"
        }
        return duration(seconds, locale: locale)
    }

    /// The languages Voz transcribes, named in the person’s language and sorted.
    static func supportedLanguageNames(locale: Locale = .current) -> [String] {
        Voz.supportedLanguages
            .map { locale.localizedString(forLanguageCode: $0) ?? $0 }
            .sorted { $0.compare($1, locale: locale) == .orderedAscending }
    }
}
