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
        let trace = StabilityTrace.begin("StartupModelContainer")
        defer { StabilityTrace.end("StartupModelContainer", trace) }
        let schema = Schema([
            Document.self,
            ListeningSession.self,
            Folder.self
        ])
        // We use the storage manager to ensure the DB writes to the shared group 
        // if available, or falls back gracefully on free tier.
        #if DEBUG
        if UIExperimentFixture.enabled {
            let container = try! ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            UIExperimentFixture.populate(container)
            return container
        }
        #endif
        let storeURL = StorageManager.shared.swiftDataURL.appendingPathComponent("Plume.sqlite")
        let modelConfiguration = ModelConfiguration(schema: schema, url: storeURL)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        // Pre-warm speech synthesis voices asynchronously off the Main Thread at launch
        AVFoundationSpeechVoiceProvider.prewarm()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                #if DEBUG
                .modifier(UIExperimentEnvironment())
                #endif
                .onAppear {
                    PlaybackCoordinator.shared.configure(container: sharedModelContainer)
                }
        }
        .modelContainer(sharedModelContainer)
    }
}
