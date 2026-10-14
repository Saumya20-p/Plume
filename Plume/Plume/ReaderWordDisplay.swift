import Foundation

/// Presentation-only state for the reader's return-to-current-word control.
struct ReaderWordDisplay: Equatable, Sendable {
    private(set) var currentWordValue: String?

    var displayText: String {
        currentWordValue ?? "Return to Current Word"
    }

    private var documentID: UUID?
    private var lastValidWord: String?

    mutating func update(word: String?, documentID: UUID, isPaused: Bool) {
        if self.documentID != documentID {
            self.documentID = documentID
            lastValidWord = nil
        }

        if let validWord = Self.validWord(word) {
            lastValidWord = validWord
            currentWordValue = validWord
        } else {
            currentWordValue = isPaused ? lastValidWord : nil
        }
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
