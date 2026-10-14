import Foundation
import PDFKit

struct ImportFileContent: Sendable {
    let title: String
    let chapters: [EPUBChapter]
    let coverImageData: Data?
    let isBook: Bool

    nonisolated static func parse(url: URL, fallbackTitle: String) throws -> ImportFileContent {
        try Task.checkCancellation()
        if url.pathExtension.lowercased() == "epub" {
            let book = try EPUBParser.parse(epubURL: url, fallbackTitle: fallbackTitle)
            return ImportFileContent(title: book.title, chapters: book.chapters, coverImageData: book.coverImageData, isBook: true)
        }
        var text = ""
        if url.pathExtension.lowercased() == "pdf" {
            guard let pdf = PDFDocument(url: url) else { throw ImportFailure.emptyFile }
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                text += (pdf.page(at: index)?.string ?? "") + "\n\n"
            }
        } else {
            text = try String(contentsOf: url, encoding: .utf8)
        }
        try Task.checkCancellation()
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ImportFailure.emptyFile }
        return ImportFileContent(title: fallbackTitle,
                                 chapters: [EPUBChapter(title: fallbackTitle, bodyText: text, wordCount: text.split(whereSeparator: \.isWhitespace).count)],
                                 coverImageData: nil, isBook: false)
    }
}
