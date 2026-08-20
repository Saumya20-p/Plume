import Foundation
import SwiftSoup

// MARK: - Data Structures

struct EPUBBook {
    let title: String
    let author: String?
    let coverImageData: Data?
    let chapters: [EPUBChapter]
}

struct EPUBChapter {
    let title: String
    let bodyText: String
    let wordCount: Int
}

// MARK: - Parser

enum EPUBParserError: LocalizedError {
    case unzipFailed
    case containerNotFound
    case invalidContainer
    case opfNotFound
    case invalidOPF
    case noChaptersFound
    
    var errorDescription: String? {
        switch self {
        case .unzipFailed: return "Failed to unzip the EPUB file."
        case .containerNotFound: return "Could not find META-INF/container.xml in the EPUB."
        case .invalidContainer: return "The container.xml file is invalid."
        case .opfNotFound: return "Could not find the package (.opf) file."
        case .invalidOPF: return "The package file is invalid."
        case .noChaptersFound: return "No readable chapters were found in this EPUB."
        }
    }
}

struct EPUBParser {
    
    /// Parse an EPUB file at the given URL and return structured book data.
    static func parse(epubURL: URL) throws -> EPUBBook {
        // 1. Create a temp directory and unzip
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("epub_\(UUID().uuidString)")
        
        try unzipEPUB(at: epubURL, to: tempDir)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // 2. Parse META-INF/container.xml to find the .opf path
        let containerURL = tempDir.appendingPathComponent("META-INF/container.xml")
        guard FileManager.default.fileExists(atPath: containerURL.path) else {
            throw EPUBParserError.containerNotFound
        }
        
        let containerXML = try String(contentsOf: containerURL, encoding: .utf8)
        let opfRelativePath = try parseContainer(xml: containerXML)
        
        // 3. Parse the .opf package file
        let opfURL = tempDir.appendingPathComponent(opfRelativePath)
        guard FileManager.default.fileExists(atPath: opfURL.path) else {
            throw EPUBParserError.opfNotFound
        }
        
        let opfXML = try String(contentsOf: opfURL, encoding: .utf8)
        let opfDir = opfURL.deletingLastPathComponent()
        let packageInfo = try parseOPF(xml: opfXML)
        
        // 4. Extract cover image if available
        var coverImageData: Data? = nil
        if let coverHref = packageInfo.coverHref {
            let coverURL = opfDir.appendingPathComponent(coverHref)
            coverImageData = try? Data(contentsOf: coverURL)
        }
        
        // 5. Extract text from each spine item
        var chapters: [EPUBChapter] = []
        var chapterIndex = 1
        
        for spineItemID in packageInfo.spineIDs {
            guard let href = packageInfo.manifest[spineItemID] else { continue }
            
            let chapterFileURL = opfDir.appendingPathComponent(href)
            guard FileManager.default.fileExists(atPath: chapterFileURL.path) else { continue }
            
            guard let xhtml = try? String(contentsOf: chapterFileURL, encoding: .utf8) else { continue }
            
            let extracted = extractChapterText(xhtml: xhtml)
            let trimmed = extracted.bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Skip empty/very short chapters (cover pages, title pages, etc.)
            guard !trimmed.isEmpty else { continue }
            let words = trimmed.split(separator: " ")
            guard words.count >= 10 else { continue }
            
            let chapterTitle = extracted.title ?? "Chapter \(chapterIndex)"
            chapters.append(EPUBChapter(
                title: chapterTitle,
                bodyText: trimmed,
                wordCount: words.count
            ))
            chapterIndex += 1
        }
        
        guard !chapters.isEmpty else {
            throw EPUBParserError.noChaptersFound
        }
        
        return EPUBBook(
            title: packageInfo.title,
            author: packageInfo.author,
            coverImageData: coverImageData,
            chapters: chapters
        )
    }
    
    // MARK: - Unzip
    
    private static func unzipEPUB(at sourceURL: URL, to destinationURL: URL) throws {
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        guard let archive = try? Data(contentsOf: sourceURL) else {
            throw EPUBParserError.unzipFailed
        }
        
        try unzipData(archive, to: destinationURL)
    }
    
    /// Minimal ZIP extraction using Foundation.
    /// Handles standard EPUB ZIP archives (stored + deflate methods).
    private static func unzipData(_ data: Data, to destinationURL: URL) throws {
        let bytes = [UInt8](data)
        let count = bytes.count
        
        // Find End of Central Directory (EOCD) signature: 0x06054b50
        var eocdOffset = -1
        for i in stride(from: count - 22, through: max(0, count - 65557), by: -1) {
            if bytes[i] == 0x50 && bytes[i+1] == 0x4B && bytes[i+2] == 0x05 && bytes[i+3] == 0x06 {
                eocdOffset = i
                break
            }
        }
        
        guard eocdOffset >= 0 else { throw EPUBParserError.unzipFailed }
        
        // Read central directory offset and entry count
        let cdOffset = Int(readUInt32(bytes, at: eocdOffset + 16))
        let entryCount = Int(readUInt16(bytes, at: eocdOffset + 10))
        
        var offset = cdOffset
        
        for _ in 0..<entryCount {
            guard offset + 46 <= count else { break }
            
            // Verify central directory signature: 0x02014b50
            guard bytes[offset] == 0x50 && bytes[offset+1] == 0x4B &&
                  bytes[offset+2] == 0x01 && bytes[offset+3] == 0x02 else { break }
            
            let compressionMethod = Int(readUInt16(bytes, at: offset + 10))
            let compressedSize = Int(readUInt32(bytes, at: offset + 20))
            let nameLength = Int(readUInt16(bytes, at: offset + 28))
            let extraLength = Int(readUInt16(bytes, at: offset + 30))
            let commentLength = Int(readUInt16(bytes, at: offset + 32))
            let localHeaderOffset = Int(readUInt32(bytes, at: offset + 42))
            
            guard offset + 46 + nameLength <= count else { break }
            let nameBytes = Array(bytes[(offset + 46)..<(offset + 46 + nameLength)])
            let fileName = String(bytes: nameBytes, encoding: .utf8) ?? ""
            
            // Move to next central directory entry
            offset += 46 + nameLength + extraLength + commentLength
            
            // Skip directories
            guard !fileName.isEmpty && !fileName.hasSuffix("/") else { continue }
            
            // Read from local file header to get the actual data offset
            guard localHeaderOffset + 30 <= count else { continue }
            let localNameLen = Int(readUInt16(bytes, at: localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(bytes, at: localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            
            guard dataStart + compressedSize <= count else { continue }
            let compressedData = Data(bytes[dataStart..<(dataStart + compressedSize)])
            
            var fileData: Data
            if compressionMethod == 0 {
                // Stored (no compression)
                fileData = compressedData
            } else if compressionMethod == 8 {
                // Deflate — use raw deflate with zlib header prepended
                var zlibData = Data([0x78, 0x9C])
                zlibData.append(compressedData)
                guard let decompressed = try? (zlibData as NSData).decompressed(using: .zlib) as Data else {
                    continue
                }
                fileData = decompressed
            } else {
                continue // Unsupported compression method
            }
            
            let fileURL = destinationURL.appendingPathComponent(fileName)
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileData.write(to: fileURL)
        }
    }
    
    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
    
    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }
    
    // MARK: - Parse container.xml
    
    private static func parseContainer(xml: String) throws -> String {
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
    
    private static func parseOPF(xml: String) throws -> PackageInfo {
        let doc = try SwiftSoup.parse(xml, "", Parser.xmlParser())
        
        // Extract metadata
        let title = (try? doc.select("dc\\:title, title").first()?.text()) ?? "Untitled Book"
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
                if let href = manifest[idref], let mt = try? doc.select("manifest item[id=\(idref)]").first()?.attr("media-type"),
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
    
    private static func extractChapterText(xhtml: String) -> (title: String?, bodyText: String) {
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
