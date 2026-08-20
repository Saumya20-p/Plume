import Foundation
import Combine
import SwiftUI

@MainActor
public class PlaybackQueueManager: ObservableObject {
    public static let shared = PlaybackQueueManager()
    
    @Published public var queue: [UUID] = [] {
        didSet {
            saveQueue()
        }
    }
    
    private let userDefaultsKey = "com.saumyapatel.Plume.playbackQueue"
    
    private init() {
        loadQueue()
    }
    
    private func loadQueue() {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let savedQueue = try? JSONDecoder().decode([UUID].self, from: data) {
            self.queue = savedQueue
        }
    }
    
    private func saveQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
    }
    
    public func enqueue(_ id: UUID) {
        if !queue.contains(id) {
            queue.append(id)
        }
    }
    
    public func insertNext(_ id: UUID) {
        if let index = queue.firstIndex(of: id) {
            queue.remove(at: index)
        }
        queue.insert(id, at: 0)
    }
    
    public func remove(_ id: UUID) {
        queue.removeAll { $0 == id }
    }
    
    public func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    public func popNext() -> UUID? {
        guard !queue.isEmpty else { return nil }
        return queue.removeFirst()
    }
    
    public func clear() {
        queue.removeAll()
    }
}
