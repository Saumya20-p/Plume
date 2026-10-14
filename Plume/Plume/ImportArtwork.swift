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
    guard let (data, response) = try? await session.data(from: url), !Task.isCancelled,
          data.count <= 5_000_000, let response = response as? HTTPURLResponse,
          (200..<300).contains(response.statusCode), response.mimeType?.hasPrefix("image/") == true else { return nil }
    return data
}
