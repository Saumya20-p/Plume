import UIKit
import Social
import UniformTypeIdentifiers
import os

struct SharedItem: Codable {
    let id: UUID
    let url: String
    let html: String?
    let dateAdded: Date
}

enum AppGroup {
    static let identifier = "group.com.saumyapatel.plume"
    
    static var containerURL: URL {
        if let sharedURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
            return sharedURL
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }
}

class ShareViewController: UIViewController {
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = UIColor.systemBackground
        
        let label = UILabel()
        label.text = "Saving to Plume..."
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        
        extractData()
    }
    
    private func extractData() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let itemProviders = extensionItem.attachments else {
            self.finish()
            return
        }
        
        let propertyListType = UTType.propertyList.identifier
        let urlType = UTType.url.identifier
        
        var foundURL: String?
        var foundHTML: String?
        
        let group = DispatchGroup()
        
        for provider in itemProviders {
            if provider.hasItemConformingToTypeIdentifier(propertyListType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: propertyListType, options: nil) { (item, error) in
                    defer { group.leave() }
                    if let dict = item as? NSDictionary,
                       let results = dict[NSExtensionJavaScriptPreprocessingResultsKey] as? NSDictionary {
                        foundURL = results["url"] as? String
                        foundHTML = results["html"] as? String
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(urlType) {
                group.enter()
                provider.loadItem(forTypeIdentifier: urlType, options: nil) { (item, error) in
                    defer { group.leave() }
                    if let url = item as? URL {
                        foundURL = url.absoluteString
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            if let url = foundURL {
                self.saveItem(url: url, html: foundHTML)
            }
            self.finish()
        }
    }
    
    private func saveItem(url: String, html: String?) {
        let item = SharedItem(id: UUID(), url: url, html: html, dateAdded: Date())
        
        do {
            let container = AppGroup.containerURL
            let fileURL = container.appendingPathComponent("shared_\(item.id.uuidString).json")
            let data = try JSONEncoder().encode(item)
            try data.write(to: fileURL)
            let logger = Logger(subsystem: "app.plume.share", category: "Share")
            logger.info("Successfully saved to \(fileURL.path, privacy: .public)")
        } catch {
            let logger = Logger(subsystem: "app.plume.share", category: "Share")
            logger.error("Failed to save: \(error.localizedDescription, privacy: .public)")
        }
    }
    
    private func finish() {
        DispatchQueue.main.async {
            self.openHostApp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
            }
        }
    }
    
    @objc private func openURL(_ url: URL) {
        return
    }
    
    private func openHostApp() {
        guard let url = URL(string: "plume://") else { return }
        
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        
        var responder: UIResponder? = self as UIResponder
        while let currentResponder = responder {
            if let appClass = NSClassFromString("UIApplication"), currentResponder.isKind(of: appClass) && currentResponder.responds(to: selector) {
                typealias OpenURLFunction = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                if let methodIMP = currentResponder.method(for: selector) {
                    let openURL = unsafeBitCast(methodIMP, to: OpenURLFunction.self)
                    openURL(currentResponder, selector, url, NSDictionary(), nil)
                    return
                }
            }
            responder = currentResponder.next
        }
        
        // Fallback: Try to get UIApplication.shared directly
        if let appClass = NSClassFromString("UIApplication") as? NSObject.Type {
            let sharedSelector = NSSelectorFromString("sharedApplication")
            if appClass.responds(to: sharedSelector), let sharedApp = appClass.perform(sharedSelector)?.takeUnretainedValue() as? UIResponder {
                if sharedApp.responds(to: selector) {
                    typealias OpenURLFunction = @convention(c) (AnyObject, Selector, URL, NSDictionary, ((Bool) -> Void)?) -> Void
                    if let methodIMP = sharedApp.method(for: selector) {
                        let openURL = unsafeBitCast(methodIMP, to: OpenURLFunction.self)
                        openURL(sharedApp, selector, url, NSDictionary(), nil)
                        return
                    }
                }
            }
        }
    }
}
