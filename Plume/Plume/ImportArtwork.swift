import Foundation

/// Optional artwork has its own short deadline and never holds up text import.
nonisolated func fetchImportArtwork(_ url: URL?) async -> Data? {
    guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 4
    config.timeoutIntervalForResource = 5
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    do {
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode),
              response.mimeType?.hasPrefix("image/") == true,
              response.expectedContentLength <= 5_000_000 else { return nil }
        var data = Data()
        for try await byte in bytes {
            guard !Task.isCancelled, data.count < 5_000_000 else { return nil }
            data.append(byte)
        }
        return data.isEmpty ? nil : data
    } catch { return nil }
}
