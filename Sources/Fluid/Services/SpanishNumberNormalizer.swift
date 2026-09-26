import Foundation

/// Rewrites Spanish number words as digits ("diecinueve punto seis" → "19.6",
/// "dos mil veintidós" → "2022"). Rule-based and on-device. Articles ("un", "una")
/// and the spoken "dos puntos" command are never touched.
nonisolated enum SpanishNumberNormalizer {
    enum Mode: String, CaseIterable, Identifiable, Sendable {
        case off
        /// 10 and above, decimals, and anything with "mil"/"millón"; 0–9 stay as words.
        case largeAndDecimals
        /// Every number, except articles and "dos puntos".
        case always

        var id: String { self.rawValue }

        var displayName: String {
            switch self {
            case .off: "Off"
            case .largeAndDecimals: "10+ and decimals"
            case .always: "Always digits"
            }
        }
    }

    private enum Kind {
        case unit, teen, tens, hundred, thousand, million, and
    }

    private struct Word {
        let kind: Kind
        let value: Int
    }

    private static let words: [String: Word] = {
        var map: [String: Word] = [:]
        let units = ["cero": 0, "uno": 1, "un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5,
                     "seis": 6, "siete": 7, "ocho": 8, "nueve": 9]
        for (word, value) in units { map[word] = Word(kind: .unit, value: value) }
        let teens = ["diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15,
                     "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
                     "veinte": 20, "veintiuno": 21, "veintiun": 21, "veintiuna": 21, "veintidos": 22,
                     "veintitres": 23, "veinticuatro": 24, "veinticinco": 25, "veintiseis": 26,
                     "veintisiete": 27, "veintiocho": 28, "veintinueve": 29]
        for (word, value) in teens { map[word] = Word(kind: .teen, value: value) }
        let tens = ["treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70,
                    "ochenta": 80, "noventa": 90]
        for (word, value) in tens { map[word] = Word(kind: .tens, value: value) }
        let hundreds = ["cien": 100, "ciento": 100, "doscientos": 200, "doscientas": 200, "trescientos": 300,
                        "trescientas": 300, "cuatrocientos": 400, "cuatrocientas": 400, "quinientos": 500,
                        "quinientas": 500, "seiscientos": 600, "seiscientas": 600, "setecientos": 700,
                        "setecientas": 700, "ochocientos": 800, "ochocientas": 800, "novecientos": 900,
                        "novecientas": 900]
        for (word, value) in hundreds { map[word] = Word(kind: .hundred, value: value) }
        map["mil"] = Word(kind: .thousand, value: 1000)
        map["millon"] = Word(kind: .million, value: 1_000_000)
        map["millones"] = Word(kind: .million, value: 1_000_000)
        map["y"] = Word(kind: .and, value: 0)
        return map
    }()

    private static let articles: Set<String> = ["un", "una", "uno"]

    private struct Token {
        let range: Range<String.Index>
        let key: String
        let digits: Int?
    }

    static func normalize(_ text: String, mode: Mode) -> String {
        guard mode != .off, !text.isEmpty else { return text }
        let tokens = self.tokenize(text)
        guard !tokens.isEmpty else { return text }

        var replacements: [(Range<String.Index>, String)] = []
        var index = 0
        while index < tokens.count {
            guard let match = self.matchNumber(tokens, from: index, in: text, mode: mode) else {
                index += 1
                continue
            }
            replacements.append((tokens[index].range.lowerBound..<tokens[match.end - 1].range.upperBound, match.text))
            index = match.end
        }

        var result = text
        for (range, replacement) in replacements.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // MARK: - Matching

    private static func matchNumber(
        _ tokens: [Token],
        from start: Int,
        in text: String,
        mode: Mode
    ) -> (end: Int, text: String)? {
        // "3 mil", "2 millones": digits followed by a scale word.
        if let digits = tokens[start].digits {
            guard start + 1 < tokens.count, self.adjacent(tokens[start], tokens[start + 1], in: text),
                  let scale = self.words[tokens[start + 1].key], scale.kind == .thousand || scale.kind == .million
            else { return nil }
            return (start + 2, String(digits * scale.value))
        }

        guard let integer = self.parseInteger(tokens, from: start, in: text) else { return nil }
        var end = integer.end
        var output = String(integer.value)
        var hasDecimal = false

        // Decimal part: "punto"/"coma" followed by number words, read digit group by digit group.
        // Repeats for version numbers ("uno punto seis punto nueve" → 1.6.9).
        while end + 1 < tokens.count,
              self.isDecimalSeparator(tokens[end].key),
              self.adjacent(tokens[end - 1], tokens[end], in: text),
              self.adjacent(tokens[end], tokens[end + 1], in: text)
        {
            var decimalDigits = ""
            var cursor = end + 1
            while cursor < tokens.count,
                  cursor == end + 1 || self.adjacent(tokens[cursor - 1], tokens[cursor], in: text),
                  let group = self.parseInteger(tokens, from: cursor, in: text, allowArticleStart: true)
            {
                decimalDigits += String(group.value)
                cursor = group.end
            }
            guard !decimalDigits.isEmpty else { break }
            output += "." + decimalDigits
            end = cursor
            hasDecimal = true
        }

        // "cinco por ciento" → "5%".
        var isPercent = false
        if end + 1 < tokens.count, tokens[end].key == "por", tokens[end + 1].key == "ciento",
           self.adjacent(tokens[end - 1], tokens[end], in: text),
           self.adjacent(tokens[end], tokens[end + 1], in: text)
        {
            output += "%"
            end += 2
            isPercent = true
        }

        let singleWord = end - start == 1 && !isPercent
        let firstKey = tokens[start].key
        if singleWord, self.articles.contains(firstKey) { return nil }
        // "dos puntos" is the spoken colon command, not a number.
        if singleWord, firstKey == "dos", end < tokens.count, tokens[end].key == "puntos" { return nil }

        switch mode {
        case .off:
            return nil
        case .largeAndDecimals:
            let usesScale = tokens[start..<end].contains { self.words[$0.key]?.kind == .thousand || self.words[$0.key]?.kind == .million }
            guard hasDecimal || isPercent || integer.value >= 10 || usesScale else { return nil }
        case .always:
            break
        }
        return (end, output)
    }

    /// Greedy parse of one well-formed Spanish cardinal. Stops before any word that would
    /// make it ill-formed, so "dos tres" stays two separate numbers.
    private static func parseInteger(
        _ tokens: [Token],
        from start: Int,
        in text: String,
        allowArticleStart: Bool = false
    ) -> (end: Int, value: Int)? {
        var millions = 0
        var thousands = 0
        var group = 0 // 0...999 being built
        var lastKind: Kind?
        var lastValid: (end: Int, value: Int)?
        var index = start

        while index < tokens.count {
            if index > start, !self.adjacent(tokens[index - 1], tokens[index], in: text) { break }
            guard let word = self.words[tokens[index].key] else { break }
            let key = tokens[index].key
            let nextKind = index + 1 < tokens.count ? self.words[tokens[index + 1].key]?.kind : nil

            var accepted = false
            switch word.kind {
            case .hundred:
                if group == 0, lastKind != .unit, lastKind != .teen, lastKind != .tens {
                    // "cien" only stands alone or before a scale; "ciento" needs more after it.
                    group = word.value
                    accepted = true
                }
            case .tens:
                if group % 100 == 0, lastKind != .unit, lastKind != .teen, lastKind != .tens {
                    group += word.value
                    accepted = true
                }
            case .teen:
                if group % 100 == 0, lastKind != .unit, lastKind != .teen, lastKind != .tens {
                    group += word.value
                    accepted = true
                }
            case .unit:
                let isArticle = self.articles.contains(key)
                if lastKind == .and {
                    group += word.value
                    accepted = true
                } else if group % 100 == 0, lastKind != .unit, lastKind != .teen, lastKind != .tens {
                    // An article only counts at the start when a scale follows ("un millón").
                    let startsDecimal = index + 2 < tokens.count
                        && self.isDecimalSeparator(tokens[index + 1].key)
                        && self.words[tokens[index + 2].key] != nil
                    if !isArticle || lastKind != nil || allowArticleStart
                        || nextKind == .thousand || nextKind == .million || startsDecimal
                    {
                        group += word.value
                        accepted = true
                    }
                }
            case .and:
                if lastKind == .tens, index + 1 < tokens.count,
                   self.words[tokens[index + 1].key]?.kind == .unit,
                   self.adjacent(tokens[index], tokens[index + 1], in: text)
                {
                    accepted = true
                }
            case .thousand:
                if thousands == 0, lastKind != .thousand, lastKind != .and {
                    thousands = (group == 0 ? 1 : group) * 1000
                    group = 0
                    accepted = true
                }
            case .million:
                if lastKind != nil, lastKind != .and, lastKind != .million {
                    millions += (thousands + group == 0 ? 1 : thousands + group) * 1_000_000
                    thousands = 0
                    group = 0
                    accepted = true
                }
            }

            guard accepted else { break }
            lastKind = word.kind
            index += 1
            // "ciento" and "y" need more words after them to be a complete number.
            if key != "ciento", word.kind != .and {
                lastValid = (index, millions + thousands + group)
            }
        }

        return lastValid
    }

    private static func isDecimalSeparator(_ key: String) -> Bool {
        key == "punto" || key == "coma"
    }

    // MARK: - Tokens

    private static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character.isNumber {
                let isDigitRun = character.isASCII && character.isNumber
                var end = index
                while end < text.endIndex,
                      isDigitRun ? (text[end].isASCII && text[end].isNumber) : text[end].isLetter
                {
                    end = text.index(after: end)
                }
                let raw = String(text[index..<end])
                let key = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "es"))
                tokens.append(Token(range: index..<end, key: key, digits: isDigitRun ? Int(raw) : nil))
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        return tokens
    }

    /// Two tokens belong to the same number only when separated by plain spaces.
    private static func adjacent(_ left: Token, _ right: Token, in text: String) -> Bool {
        let gap = text[left.range.upperBound..<right.range.lowerBound]
        return !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }
}

extension ASRService {
    static func applyNumberFormatting(_ text: String) -> String {
        SpanishNumberNormalizer.normalize(text, mode: SettingsStore.shared.numberFormattingMode)
    }
}
