import Foundation
import NaturalLanguage

public struct TextSegmenter {
    public struct Chunk: Sendable {
        let id: DocumentSegmentID
        public let text: String
        public let range: Range<String.Index>
        public let nsRange: NSRange
        let utf16Range: UTF16TextRange
        
        init(
            id: DocumentSegmentID,
            text: String,
            range: Range<String.Index>,
            nsRange: NSRange
        ) {
            self.id = id
            self.text = text
            self.range = range
            self.nsRange = nsRange
            self.utf16Range = id.utf16Range
        }
    }
    
    public static func segment(documentID: UUID, text: String) -> [Chunk] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        
        var chunks: [Chunk] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { tokenRange, _ in
            let chunkText = String(text[tokenRange])
            let nsRange = NSRange(tokenRange, in: text)
            let id = DocumentSegmentID(
                documentID: documentID,
                ordinal: chunks.count,
                utf16Range: UTF16TextRange(nsRange)
            )
            chunks.append(Chunk(id: id, text: chunkText, range: tokenRange, nsRange: nsRange))
            return true
        }
        
        return chunks
    }
}
