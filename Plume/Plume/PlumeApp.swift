//
//  PlumeApp.swift
//  Plume
//
//  Created by Saumya Patel on 8/10/26.
//

import SwiftUI
import SwiftData

@main
struct PlumeApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Document.self,
            ListeningSession.self,
            Folder.self
        ])
        // We use the storage manager to ensure the DB writes to the shared group 
        // if available, or falls back gracefully on free tier.
        let storeURL = StorageManager.shared.swiftDataURL.appendingPathComponent("Plume.sqlite")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    PlaybackCoordinator.shared.configure(container: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
