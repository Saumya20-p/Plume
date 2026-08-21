import Foundation
import NaturalLanguage

public struct TextSegmenter {
    public struct Chunk: Sendable {
        public let text: String
        public let range: Range<String.Index>
        public let nsRange: NSRange
        
        public init(text: String, range: Range<String.Index>, nsRange: NSRange) {
            self.text = text
            self.range = range
            self.nsRange = nsRange
        }
    }
    
    public static func segment(text: String) -> [Chunk] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        var chunks: [Chunk] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let chunkText = String(text[tokenRange])
            let nsRange = NSRange(tokenRange, in: text)
            chunks.append(Chunk(text: chunkText, range: tokenRange, nsRange: nsRange))
            return true
        }
        
        return chunks
    }
}
