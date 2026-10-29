import Foundation

enum HanjuLanguage {
    static var system: String { (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("ko") ? "ko" : "en" }
    static func resolve(_ value: Any?) -> String { let language = value as? String; return language == "ko" || language == "en" ? language! : system }
    static func text(_ ko: String, _ en: String, language: String) -> String { language == "en" ? en : ko }
    static func days(_ language: String) -> [String] { language == "en" ? ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"] : ["월","화","수","목","금","토","일"] }
}
