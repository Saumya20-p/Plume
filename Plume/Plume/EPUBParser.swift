import Foundation
import SwiftSoup
import ZIPFoundation

enum EPUBParserError: Error, LocalizedError {
    case unzipFailed
    case containerNotFound
    case invalidContainer
    case opfNotFound
    case invalidOPF
    case chapterExtractionFailed
    
    var errorDescription: String? {
        switch self {
        case .unzipFailed: return "Failed to unzip the EPUB file."
        case .containerNotFound: return "Invalid EPUB: Missing META-INF/container.xml"
        case .invalidContainer: return "Invalid EPUB: container.xml is malformed"
        case .opfNotFound: return "Invalid EPUB: OPF package file not found"
        case .invalidOPF: return "Invalid EPUB: OPF package is malformed"
        case .chapterExtractionFailed: return "Failed to extract chapter text"
        }
    }
}

struct EPUBChapter: Sendable {
    let title: String
    let bodyText: String
    let wordCount: Int
}

struct EPUBBook: Sendable {
    let title: String
    let author: String?
    let chapters: [EPUBChapter]
    let coverImageData: Data?
}

struct EPUBParser {
    
    /// Parse an EPUB file at the given URL and return structured book data.
    nonisolated static func parse(epubURL: URL, fallbackTitle: String = "Untitled Book") throws -> EPUBBook {
        try Task.checkCancellation()
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("epub_\(UUID().uuidString)")
        
        defer { try? fileManager.removeItem(at: tempDir) }
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
            try fileManager.unzipItem(at: epubURL, to: tempDir)
        } catch {
            throw EPUBParserError.unzipFailed
        }
        try Task.checkCancellation()
        
        // 2. Parse META-INF/container.xml to find the .opf path
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard fileManager.fileExists(atPath: containerURL.path) else {
            throw EPUBParserError.containerNotFound
        }
        
        let containerXML = try String(contentsOf: containerURL, encoding: .utf8)
        let opfRelativePath = try parseContainer(xml: containerXML)
        
        // 3. Parse the .opf package file
        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        guard fileManager.fileExists(atPath: opfURL.path) else {
            throw EPUBParserError.opfNotFound
        }
        
        let opfXML = try String(contentsOf: opfURL, encoding: .utf8)
        let opfDir = opfURL.deletingLastPathComponent()
        let packageInfo = try parseOPF(xml: opfXML, fallbackTitle: fallbackTitle)
        
        // 4. Extract cover image if available
        var coverImageData: Data? = nil
        if let coverHref = packageInfo.coverHref {
            let decodedHref = coverHref.removingPercentEncoding ?? coverHref
            let coverURL = opfDir.appendingPathComponent(decodedHref)
            coverImageData = try? Data(contentsOf: coverURL)
        }
        
        // 5. Extract text from each spine item
        var chapters: [EPUBChapter] = []
        var chapterIndex = 1
        
        for idref in packageInfo.spineIDs {
            try Task.checkCancellation()
            guard let href = packageInfo.manifest[idref] else { continue }
            let decodedHref = href.removingPercentEncoding ?? href
            let chapterURL = opfDir.appendingPathComponent(decodedHref)
            
            guard fileManager.fileExists(atPath: chapterURL.path),
                  let htmlStr = try? String(contentsOf: chapterURL, encoding: .utf8) else {
                continue
            }
            
            let (extractedTitle, bodyText) = extractChapterText(xhtml: htmlStr)
            let finalTitle = extractedTitle ?? "Chapter \(chapterIndex)"
            
            // Basic word count
            let wordCount = bodyText.split { $0.isWhitespace }.count
            if wordCount > 0 {
                chapters.append(EPUBChapter(title: finalTitle, bodyText: bodyText, wordCount: wordCount))
                chapterIndex += 1
            }
        }
        
        guard !chapters.isEmpty else {
            throw EPUBParserError.chapterExtractionFailed
        }
        
        return EPUBBook(
            title: packageInfo.title,
            author: packageInfo.author,
            chapters: chapters,
            coverImageData: coverImageData
        )
    }
    
    // MARK: - Parse container.xml
    
    nonisolated private static func parseContainer(xml: String) throws -> String {
        let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        guard let rootfile = try doc.select("rootfile").first(),
              let fullPath = try? rootfile.attr("full-path"),
              !fullPath.isEmpty else {
            throw EPUBParserError.invalidContainer
        }
        return fullPath
    }
    
    // MARK: - Parse .opf
    
    private struct PackageInfo {
        let title: String
        let author: String?
        let manifest: [String: String]  // id -> href
        let spineIDs: [String]          // ordered list of manifest IDs
        let coverHref: String?
    }
    
    nonisolated private static func parseOPF(xml: String, fallbackTitle: String) throws -> PackageInfo {
        let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        
        // Extract metadata
        var title = (try? doc.select("dc\\:title, title").first()?.text()) ?? fallbackTitle
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            title = fallbackTitle
        }
        
        let author = try? doc.select("dc\\:creator, creator").first()?.text()
        
        // Find cover meta tag if present
        var coverMetaID: String?
        if let metaTags = try? doc.select("meta[name=cover]") {
            coverMetaID = try? metaTags.first()?.attr("content")
        }
        
        // Build manifest: id -> href
        var manifest: [String: String] = [:]
        var coverHref: String? = nil
        
        let manifestItems = try doc.select("manifest item")
        for item in manifestItems {
            let id = try item.attr("id")
            let href = try item.attr("href")
            let mediaType = try? item.attr("media-type")
            let properties = try? item.attr("properties")
            
            manifest[id] = href
            
            // Check if this item is the cover image
            if (properties == "cover-image") || (coverMetaID != nil && id == coverMetaID) {
                coverHref = href
            } else if coverHref == nil && id.lowercased().contains("cover") && (mediaType?.contains("image") == true) {
                // Fallback for missing meta tag
                coverHref = href
            }
        }
        
        // Build spine: ordered list of itemref idref values
        var spineIDs: [String] = []
        let spineItems = try doc.select("spine itemref")
        for itemref in spineItems {
            let idref = try itemref.attr("idref")
            if !idref.isEmpty {
                // Only add to spine if it's an XHTML document (avoiding images accidentally put in spine)
                if manifest[idref] != nil, let mt = try? doc.select("manifest item[id='\(idref)']").first()?.attr("media-type"),
                   (mt.contains("xhtml") || mt.contains("html") || mt.contains("xml")) {
                    spineIDs.append(idref)
                } else if let href = manifest[idref], href.lowercased().hasSuffix("xhtml") || href.lowercased().hasSuffix("html") {
                     spineIDs.append(idref)
                }
            }
        }
        
        guard !spineIDs.isEmpty else {
            throw EPUBParserError.invalidOPF
        }
        
        return PackageInfo(
            title: title,
            author: author,
            manifest: manifest,
            spineIDs: spineIDs,
            coverHref: coverHref
        )
    }
    
    // MARK: - Extract Chapter Text
    
    nonisolated private static func extractChapterText(xhtml: String) -> (title: String?, bodyText: String) {
        guard let doc = try? SwiftSoup.parse(xhtml) else {
            return (nil, "")
        }
        
        // Strip noise elements
        let noiseSelectors = ["script", "style", "nav", "noscript", "svg", "figure", "figcaption"]
        for selector in noiseSelectors {
            _ = try? doc.select(selector).remove()
        }
        
        // Try to extract a chapter heading
        var chapterTitle: String? = nil
        for headingTag in ["h1", "h2", "h3"] {
            if let heading = try? doc.select(headingTag).first(),
               let text = try? heading.text().trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty && text.count < 200 {
                chapterTitle = text
                break
            }
        }
        
        // Extract body text from paragraphs
        var bodyText = ""
        if let body = try? doc.select("body").first() {
            if let paragraphs = try? body.select("p") {
                for p in paragraphs {
                    if let text = try? p.text().trimmingCharacters(in: .whitespacesAndNewlines),
                       !text.isEmpty {
                        bodyText += text + "\n\n"
                    }
                }
            }
            
            // Fallback: if no <p> tags found, grab all text
            if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                bodyText = (try? body.text()) ?? ""
            }
        }
        
        return (chapterTitle, bodyText)
    }
}
