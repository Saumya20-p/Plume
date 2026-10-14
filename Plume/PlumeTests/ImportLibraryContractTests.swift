import Foundation
import Testing
@testable import Plume

struct ImportLibraryContractTests {
    @Test func capturedDestinationSurvivesRetryAndManualFallback() throws {
        let originalID = UUID()
        var currentFolderID = originalID
        let captured = ImportDestination(folderID: currentFolderID, name: "Original Folder")
        currentFolderID = UUID()
        let available = Set([originalID, currentFolderID])
        #expect(try captured.resolveFolderID(availableIDs: available) == originalID)
        #expect(captured.name == "Original Folder")
        #expect(throws: ImportFailure.self) { try captured.resolveFolderID(availableIDs: [currentFolderID]) }
    }

    @Test func epubUsesCapturedFolderAndLibraryCreatesNewBook() {
        let folder = ImportDestination(folderID: UUID(), name: "Selected Folder")
        #expect(!folder.createsBookFolder(isEPUB: true))
        #expect(ImportDestination().createsBookFolder(isEPUB: true))
        #expect(!ImportDestination().createsBookFolder(isEPUB: false))
    }

    @Test(arguments: ["", "example.com/chapter", "file:///tmp/chapter", "https://", "javascript:alert(1)"])
    func invalidLinksHaveAnExplicitFailure(_ link: String) {
        #expect(throws: ImportFailure.self) { try validatedImportURL(link) }
    }

    @Test func acceptsAndTrimsHTTPLinks() throws {
        #expect(try validatedImportURL("  https://example.com/chapter\n").absoluteString == "https://example.com/chapter")
        #expect(try validatedImportURL("http://example.com").scheme == "http")
    }

    @MainActor @Test func cancellationWinsOverLateSuccessAndTimeout() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let gate = ImportCompletionGate<String>(continuation)
                #expect(gate.finish(.failure(CancellationError())))
                #expect(!gate.finish(.success("late chapter")))
                #expect(!gate.finish(.failure(URLError(.timedOut))))
            }
            Issue.record("Cancellation should throw")
        } catch {
            #expect(error is CancellationError)
        }
    }

    @MainActor @Test func timeoutWinsOverLateCallbacks() async {
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                let gate = ImportCompletionGate<String>(continuation)
                #expect(gate.finish(.failure(URLError(.timedOut))))
                #expect(!gate.finish(.success("late chapter")))
            }
            Issue.record("Timeout should throw")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
    }

    @Test func searchIncludesFolderChaptersAndExcludesDeletedChapters() {
        let folderID = UUID()
        #expect(LibrarySearchScope.matches(title: "A Known Chapter", progress: 0.3, folderID: folderID,
                                           deleted: false, query: " known ", filter: .all))
        #expect(!LibrarySearchScope.matches(title: "A Known Chapter", progress: 0.3, folderID: folderID,
                                            deleted: true, query: "known", filter: .all))
        #expect(!LibrarySearchScope.matches(title: "A Known Chapter", progress: 0.3, folderID: folderID,
                                            deleted: false, query: "", filter: .all))
    }

    @Test func searchKeepsProgressFilterAndBoundaryConsistent() {
        #expect(LibrarySearchScope.matches(title: "Chapter", progress: 0.98, folderID: UUID(),
                                           deleted: false, query: "chapter", filter: .inProgress))
        #expect(!LibrarySearchScope.matches(title: "Chapter", progress: 0.99, folderID: UUID(),
                                            deleted: false, query: "chapter", filter: .inProgress))
        #expect(LibrarySearchScope.matches(title: "Chapter", progress: 0.99, folderID: UUID(),
                                           deleted: false, query: "chapter", filter: .finished))
        #expect(!LibraryFilter.inProgress.matches(progress: 0))
    }
}
