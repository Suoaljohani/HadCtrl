import Foundation

/// Parses user-entered numbers in Arabic-Indic, Extended Arabic-Indic or Latin
/// digits with Arabic or Latin decimal separators (spec §10). Returns nil for
/// anything ambiguous — never a silent zero.
enum NumberInput {
    static func parseDecimal(_ raw: String) -> Decimal? {
        var s = ""
        var sawSeparator = false
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        for (index, ch) in trimmed.enumerated() {
            switch ch {
            case "0"..."9":
                s.append(ch)
            case "٠"..."٩":
                s.append(Character(String(ch.unicodeScalars.first!.value - 0x0660)))
            case "۰"..."۹":
                s.append(Character(String(ch.unicodeScalars.first!.value - 0x06F0)))
            case ".", "٫", ",":
                // "," is accepted as a decimal separator only once; thousands
                // separators are not accepted to avoid 1,234 vs 1.234 ambiguity.
                guard !sawSeparator else { return nil }
                sawSeparator = true
                s.append(".")
            case "-", "−":
                guard index == 0 else { return nil }
                s.append("-")
            case "٬", "\u{00A0}", " ":
                return nil
            default:
                return nil
            }
        }
        guard s.contains(where: { $0.isNumber }), !s.hasSuffix("."), !s.hasPrefix(".") else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }
}

/// Display formatting. Rounding happens only here (spec §10).
struct NumberStyle: Sendable, Equatable {
    enum Digits: String, Sendable { case arabicIndic, latin }
    var digits: Digits = NumberStyle.preferredDigits

    /// The user's digit preference (Settings → Appearance); Arabic-Indic unless
    /// Latin digits were chosen (D-35).
    static var preferredDigits: Digits {
        UserDefaults.standard.bool(forKey: "hc.pref.latinDigits") ? .latin : .arabicIndic
    }

    func format(_ value: Decimal, fractionDigits: Int = 1) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = fractionDigits
        f.roundingMode = .halfUp
        f.locale = Locale(identifier: digits == .arabicIndic ? "ar_SA" : "en_US_POSIX")
        f.usesGroupingSeparator = false
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    func percent(_ value: Decimal) -> String {
        format(value) + (digits == .arabicIndic ? "٪" : "%")
    }
}
