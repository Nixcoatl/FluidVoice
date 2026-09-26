import Foundation
import NaturalLanguage

extension ASRService {
    /// A paragraph closes at the first sentence end once it reaches this many characters.
    static let smartParagraphCharacterLimit = 350

    /// Breaks long dictation into paragraphs at sentence boundaries so a long voice note
    /// doesn't arrive as a wall of text. Uses Apple's NaturalLanguage sentence tokenizer,
    /// fully on-device. Existing line breaks (e.g. a spoken "new paragraph") are kept and
    /// each block between them is split on its own.
    static func applySmartParagraphs(_ text: String) -> String {
        guard SettingsStore.shared.smartParagraphsEnabled else { return text }
        return self.splitIntoSmartParagraphs(text, characterLimit: self.smartParagraphCharacterLimit)
    }

    static func splitIntoSmartParagraphs(_ text: String, characterLimit: Int) -> String {
        guard text.count > characterLimit else { return text }
        return text
            .components(separatedBy: "\n")
            .map { self.splitBlockIntoParagraphs($0, characterLimit: characterLimit) }
            .joined(separator: "\n")
    }

    private static func splitBlockIntoParagraphs(_ block: String, characterLimit: Int) -> String {
        guard block.count > characterLimit else { return block }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = block
        var paragraphs: [String] = []
        var current = ""
        tokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { range, _ in
            let sentence = block[range].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { return true }
            current += current.isEmpty ? sentence : " " + sentence
            if current.count >= characterLimit {
                paragraphs.append(current)
                current = ""
            }
            return true
        }

        if !current.isEmpty {
            // Fold a short trailing fragment into the previous paragraph instead of orphaning it.
            if let last = paragraphs.last, current.count < characterLimit / 3 {
                paragraphs[paragraphs.count - 1] = last + " " + current
            } else {
                paragraphs.append(current)
            }
        }

        guard paragraphs.count > 1 else { return block }
        return paragraphs.joined(separator: "\n\n")
    }
}
