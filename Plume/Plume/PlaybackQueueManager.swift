import Foundation
import Combine
import SwiftUI

@MainActor
public class PlaybackQueueManager: ObservableObject {
    public static let shared = PlaybackQueueManager()
    
    @Published public var queue: [UUID] = []
    
    private let defaults: UserDefaults
    private let userDefaultsKey = "com.saumyapatel.Plume.playbackQueue"
    private var cancellables = Set<AnyCancellable>()
    
    internal init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadQueue()
        
        $queue
            .dropFirst()
            .debounce(for: .seconds(1.0), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.performSaveQueue()
            }
            .store(in: &cancellables)
    }
    
    private func loadQueue() {
        if let data = defaults.data(forKey: userDefaultsKey),
           let savedQueue = try? JSONDecoder().decode([UUID].self, from: data) {
            self.queue = savedQueue
        }
    }
    
    private func performSaveQueue() {
        if let data = try? JSONEncoder().encode(queue) {
            defaults.set(data, forKey: userDefaultsKey)
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
    
    public func remove(documentID: UUID) { remove(documentID) }

    public func remove(_ id: UUID) {
        queue.removeAll { $0 == id }
    }
    
    public func skipTo(_ id: UUID) {
        if let index = queue.firstIndex(of: id) {
            // Keep only the items that come AFTER the tapped item
            queue = Array(queue.dropFirst(index + 1))
        }
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
