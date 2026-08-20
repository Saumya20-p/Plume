import Foundation
import SwiftSoup

public struct ContentExtractor {
    
    public static func extract(html: String, sourceURL: URL?) -> (title: String, body: String, failed: Bool, coverImageURL: URL?) {
        guard let doc = try? SwiftSoup.parse(html) else {
            return ("Unknown Chapter", "", true, nil)
        }
        
        var coverImageURL: URL? = nil
        if let ogImage = try? doc.select("meta[property='og:image']").first()?.attr("content"),
           let url = URL(string: ogImage, relativeTo: sourceURL) {
            coverImageURL = url
        } else if let twitterImage = try? doc.select("meta[name='twitter:image']").first()?.attr("content"),
                  let url = URL(string: twitterImage, relativeTo: sourceURL) {
            coverImageURL = url
        }
        
        // Fallback: look for an img tag that looks like a cover
        if coverImageURL == nil {
            if let imgs = try? doc.select("img") {
                for img in imgs {
                    let src = (try? img.attr("src")) ?? ""
                    let className = (try? img.attr("class"))?.lowercased() ?? ""
                    let alt = (try? img.attr("alt"))?.lowercased() ?? ""
                    
                    if src.isEmpty || src.contains("data:image") { continue }
                    
                    // Skip obvious UI icons
                    if src.contains("logo") || src.contains("avatar") || src.contains("icon") ||
                       className.contains("logo") || className.contains("avatar") || className.contains("icon") ||
                       alt.contains("logo") || alt.contains("avatar") {
                        continue
                    }
                    
                    // If it specifically says cover or thumb, prioritize it
                    if src.contains("cover") || src.contains("thumb") || className.contains("cover") || className.contains("thumb") {
                        if let url = URL(string: src, relativeTo: sourceURL) {
                            coverImageURL = url
                            break
                        }
                    } else if coverImageURL == nil {
                        // Otherwise, just keep the first reasonable image we find as a fallback
                        if let url = URL(string: src, relativeTo: sourceURL) {
                            coverImageURL = url
                        }
                    }
                }
            }
        }
        
        // 1. Strip noise
        let noiseSelectors = [
            "script", "style", "nav", "header", "footer", "aside", "noscript",
            ".ad", ".sidebar", ".comment", ".comments", ".share", ".nav", ".menu", ".related", ".footer",
            "#ad", "#sidebar", "#comments", "#nav", "#menu",
            ".skip-link", ".skip-to-content", ".sr-only", ".screen-reader-text", "[role=navigation]"
        ]
        
        for selector in noiseSelectors {
            _ = try? doc.select(selector).remove()
        }
        
        // 2. Extract title
        var title = "Unknown Chapter"
        if let titleElement = try? doc.select("title").first() {
            title = (try? titleElement.text()) ?? "Unknown Chapter"
        } else if let h1 = try? doc.select("h1").first() {
            title = (try? h1.text()) ?? "Unknown Chapter"
        }
        
        // Clean title
        title = title.components(separatedBy: "|").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
        title = title.components(separatedBy: "-").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? title
        
        // 3. Find content block
        var bestElement: Element? = try? doc.select("body").first()
        var highestScore: Double = 0
        
        if let candidates = try? doc.select("article, div, main, section") {
            for el in candidates {
                let text = try? el.text()
                let textLength = Double(text?.count ?? 0)
                if textLength < 100 { continue }
                
                let htmlLength = Double((try? el.outerHtml())?.count ?? 0)
                let links = (try? el.select("a"))?.count ?? 0
                let linkPenalty = Double(links * 10)
                
                // Square the textLength to heavily favor the node where the *bulk* of the text is dense
                let score = (textLength * textLength) / (htmlLength + linkPenalty + 1)
                
                if score > highestScore {
                    highestScore = score
                    bestElement = el
                }
            }
        }
        
        guard let contentNode = bestElement else {
            return (title, "", true, coverImageURL)
        }
        
        // 4. Extract paragraphs cleanly
        var bodyText = ""
        if let paragraphs = try? contentNode.select("p") {
            for p in paragraphs {
                let text = try? p.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if let t = text, !t.isEmpty {
                    bodyText += t + "\n\n"
                }
            }
        }
        
        // If we didn't find any p tags, fallback to raw text
        if bodyText.isEmpty {
            bodyText = (try? contentNode.text()) ?? ""
        }
        
        bodyText = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 5. Fail if too short
        let words = bodyText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let failed = words.count < 300
        
        return (title, bodyText, failed, coverImageURL)
    }
}
