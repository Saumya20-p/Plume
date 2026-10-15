import Foundation

/// Presentation-only state for the reader's return-to-current-word control.
struct ReaderWordDisplay: Equatable, Sendable {
    private(set) var currentWordValue: String?

    var displayText: String {
        currentWordValue ?? "Return to Current Word"
    }

    private var documentID: UUID?
    private var lastValidWord: String?
    private var didInitializePosition = false

    mutating func update(
        word: String?, documentID: UUID, isPaused: Bool,
        text: String? = nil, rangeLocation: Int? = nil, savedPosition: Int? = nil
    ) {
        let isNewDocument = self.documentID != documentID
        if isNewDocument {
            self.documentID = documentID
            lastValidWord = nil
            didInitializePosition = false
        }

        // A marker belongs to the current document only when the caller has checked
        // playback ownership. Saved position is an initialization fallback, never a
        // replacement for a transient gap after playback has advanced.
        let directWord = Self.validWord(word)
        let canResolveMarker = word?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let resolved = lastValidWord == nil && directWord == nil && canResolveMarker ? text.flatMap { text in
            if let rangeLocation { return Self.word(in: text, atUTF16Offset: rangeLocation) }
            if !didInitializePosition, let savedPosition { return Self.word(in: text, atUTF16Offset: savedPosition) }
            return nil
        } : nil
        if directWord != nil || rangeLocation != nil || (text != nil && savedPosition != nil) {
            didInitializePosition = true
        }
        if let validWord = directWord ?? resolved {
            lastValidWord = validWord
            currentWordValue = validWord
        } else {
            currentWordValue = lastValidWord
        }
    }

    /// Enclosing lexical word; between words choose the next, and at the trailing
    /// punctuation/EOF choose the preceding word. Offsets use the reader's UTF-16
    /// coordinate space, including offsets inside a composed character.
    static func word(in text: String, atUTF16Offset offset: Int) -> String? {
        guard offset >= 0, offset <= text.utf16.count else { return nil }
        var words: [(text: String, range: Range<Int>)] = []
        var token = ""
        var tokenStart = 0
        var position = 0
        func isWordCharacter(_ character: Character) -> Bool {
            character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            let length = String(character).utf16.count
            let internalJoiner = ["'", "’", "-"].contains(String(character)) &&
                index > 0 && index + 1 < characters.count &&
                isWordCharacter(characters[index - 1]) && isWordCharacter(characters[index + 1])
            if isWordCharacter(character) || internalJoiner {
                if token.isEmpty { tokenStart = position }
                token.append(character)
            } else if !token.isEmpty {
                words.append((token, tokenStart..<position))
                token = ""
            }
            position += length
        }
        if !token.isEmpty { words.append((token, tokenStart..<position)) }
        return words.first(where: { $0.range.contains(offset) || $0.range.lowerBound >= offset })?.text ?? words.last?.text
    }

    private static func validWord(_ word: String?) -> String? {
        guard let word else { return nil }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              trimmed.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
                       .modifierLetter, .otherLetter, .decimalNumber,
                       .letterNumber, .otherNumber:
                      return true
                  default:
                      return false
                  }
              }) else { return nil }
        return trimmed
    }
}
