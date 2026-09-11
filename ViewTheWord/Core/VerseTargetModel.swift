import Foundation
import Combine

struct SearchHit: Identifiable, Sendable {
    let pair: TranslationPair
    let matchedPrimary: Bool
    let matchedSecondary: Bool
    var id: VerseCoordinate { pair.id }
}

struct SearchPage: Identifiable, Sendable {
    let id: UUID
    let request: TextSearchRequest
    let sources: BibleSources
    let hits: [SearchHit]
    let hasMore: Bool
    var cursor: VerseCoordinate? { hits.last?.id }

    init(id: UUID = UUID(), request: TextSearchRequest, sources: BibleSources, hits: [SearchHit], hasMore: Bool) {
        self.id = id
        self.request = request
        self.sources = sources
        self.hits = hits
        self.hasMore = hasMore
    }
}

struct NavigationResult {
    let reference: VerseReference
    let requestedAvailable: Bool
    let projection: PreparedProjection?
}

enum NavigationError: LocalizedError {
    case chapterUnavailable

    var errorDescription: String? {
        "This chapter is unavailable in the selected translations."
    }
}

/// Selected reference, chapter rows and their translation identities are one published value.
/// The shared LiveProjectionController consumes prepared projection intents; this model never opens a window or publishes live content.
@MainActor
final class VerseTargetModel: ObservableObject {
    struct NavigationState {
        let reference: VerseReference
        let chapter: LoadedChapter?
    }
    @Published private(set) var navigation = NavigationState(reference: VerseReference(book: "John", chapter: 3, verse: 16)!, chapter: nil)
    @Published private(set) var searchPage: SearchPage?
    @Published private(set) var isLoading = false
    @Published private(set) var isProjecting = false
    @Published var message: String?
    var verseQuery: VerseQuery { navigation.reference.verseQuery }
    var verseRowData: VerseRowData { navigation.chapter?.data ?? emptyRows }
    private let emptyRows = VerseRowData.empty
    private(set) var searchRequest: TextSearchRequest?
    private var pendingReference: VerseReference?
    var refreshReference: VerseReference? { pendingReference ?? (navigation.chapter == nil ? nil : navigation.reference) }
    private var task: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private var generation = UUID()
    private var projectionGeneration = UUID()
    private var navigationProjectionID: UUID?
    private var projectionCancellation: (@MainActor () -> Void)?
    private var readers: [URL: any BibleReading] = [:]
    private var libraryRevision: Int?
    private let readerFactory: @Sendable (URL) -> any BibleReading

    init(readerFactory: @escaping @Sendable (URL) -> any BibleReading = { Bible(dbUrl: $0) }) {
        self.readerFactory = readerFactory
    }
    deinit { task?.cancel(); projectionTask?.cancel() }

    private func reader(_ url: URL, revision: Int) -> any BibleReading {
        if libraryRevision != revision { readers = [:]; libraryRevision = revision }
        if let reader = readers[url] { return reader }
        let reader = readerFactory(url)
        readers[url] = reader
        return reader
    }
    private func databases(_ sources: BibleSources) -> (any BibleReading, (any BibleReading)?) {
        (reader(sources.primary, revision: sources.revision), sources.secondary.map { reader($0, revision: sources.revision) })
    }
    private func begin() -> UUID {
        if navigationProjectionID == projectionGeneration { cancelProjection() }
        task?.cancel()
        generation = UUID()
        pendingReference = nil
        isLoading = true
        message = nil
        return generation
    }
    private func current(_ id: UUID) -> Bool { id == generation && !Task.isCancelled }

    @discardableResult
    func cancelProjection(updateStatus: Bool = true) -> UUID {
        let onCancel = projectionCancellation
        projectionCancellation = nil
        projectionTask?.cancel()
        projectionTask = nil
        projectionGeneration = UUID()
        navigationProjectionID = nil
        if updateStatus && isProjecting { isProjecting = false }
        onCancel?()
        return projectionGeneration
    }
    func finishProjectionCancellation(_ cancellationID: UUID) {
        guard cancellationID == projectionGeneration else { return }
        if isProjecting { isProjecting = false }
    }
    func cancelLoading(clearSearch: Bool = false) {
        if navigationProjectionID == projectionGeneration { cancelProjection() }
        task?.cancel()
        task = nil
        generation = UUID()
        pendingReference = nil
        isLoading = false
        if clearSearch { searchPage = nil; searchRequest = nil }
    }
    func cancelAll() { cancelLoading(); cancelProjection() }

    /// Current requests complete once with success or failure. Canceled or
    /// superseded requests never invoke completion or commit late results.
    func navigate(to reference: VerseReference, sources: BibleSources, project: Bool = false,
                  onProjectionCancelled: @escaping @MainActor () -> Void = {},
                  onComplete: @escaping @MainActor (Result<NavigationResult, Error>) -> Void) {
        let id = begin()
        pendingReference = reference
        if project {
            cancelProjection()
            projectionCancellation = onProjectionCancelled
            isProjecting = true
        }
        let projectionID = projectionGeneration
        if project { navigationProjectionID = projectionID }
        searchPage = nil
        searchRequest = nil
        let (primary, secondary) = databases(sources)
        task = Task { [weak self] in
            do {
                async let first = primary.chapter(reference)
                async let second = secondary?.chapter(reference)
                let chapter = try await LoadedChapter(reference: reference, sources: sources, primary: first, secondary: second ?? [])
                guard let self, self.current(id) else { return }
                self.isLoading = false
                self.task = nil
                self.pendingReference = nil
                guard let resolved = chapter.resolvedReference(reference) else {
                    self.navigation = NavigationState(reference: reference, chapter: chapter)
                    self.finishNavigationProjection(projectionID)
                    let error = NavigationError.chapterUnavailable
                    self.message = error.localizedDescription
                    onComplete(.failure(error))
                    return
                }
                self.navigation = NavigationState(reference: resolved, chapter: chapter)
                let requested = chapter.row(at: reference)
                if requested == nil {
                    self.message = "\(reference.verseQuery.title) is unavailable in these translations. Showing \(resolved.verseQuery.title)."
                }
                var prepared: PreparedProjection?
                if project, projectionID == self.projectionGeneration, let requested {
                    prepared = PreparedProjection(pair: requested, sources: sources, owner: .textInputTarget(reference))
                }
                self.finishNavigationProjection(projectionID)
                onComplete(.success(NavigationResult(reference: resolved, requestedAvailable: requested != nil, projection: prepared)))
            } catch {
                guard let self, self.current(id) else { return }
                self.isLoading = false
                self.pendingReference = nil
                self.finishNavigationProjection(projectionID)
                self.task = nil
                // Never leave old translation text behind new picker values after a failed refresh.
                if self.navigation.chapter?.sources != sources {
                    self.navigation = NavigationState(reference: reference, chapter: nil)
                }
                self.message = error.localizedDescription
                onComplete(.failure(error))
            }
        }
    }

    private func finishNavigationProjection(_ id: UUID) {
        if navigationProjectionID == id && projectionGeneration == id {
            navigationProjectionID = nil
            projectionCancellation = nil
            isProjecting = false
        }
    }

    func prepareRowProjection(_ reference: VerseReference, sources: BibleSources) -> PreparedProjection? {
        guard !isLoading, let chapter = navigation.chapter, chapter.sources == sources,
              let row = chapter.row(at: reference) else { return nil }
        cancelAll()
        message = nil
        navigation = NavigationState(reference: reference, chapter: chapter)
        return PreparedProjection(pair: row, sources: sources, owner: .verseRowSelection(reference))
    }

    func requestProjection(owner: ProjectionOwner, sources: BibleSources,
                           onCancelled: @escaping @MainActor () -> Void = {},
                           onComplete: @escaping @MainActor (PreparedProjection?) -> Void) {
        cancelProjection()
        let id = projectionGeneration
        projectionCancellation = onCancelled
        isProjecting = true
        // Clear the previous attempt's error now, so a later successful lookup
        // cannot erase an error from newer, independent navigation work.
        message = nil
        let (primary, secondary) = databases(sources)
        projectionTask = Task { [weak self] in
            do {
                async let first = primary.verses([owner.reference])
                async let second = secondary?.verses([owner.reference])
                let pairs = try await LoadedChapter.merge(primary: first, secondary: second ?? [])
                guard let self, id == self.projectionGeneration, !Task.isCancelled else { return }
                self.projectionCancellation = nil
                self.isProjecting = false
                self.projectionTask = nil
                let prepared = pairs.first(where: { $0.reference == owner.reference }).flatMap {
                    PreparedProjection(pair: $0, sources: sources, owner: owner)
                }
                if prepared == nil { self.message = "\(owner.reference.verseQuery.title) is unavailable in the selected translations." }
                onComplete(prepared)
            } catch {
                guard let self, id == self.projectionGeneration, !Task.isCancelled else { return }
                self.projectionCancellation = nil
                self.isProjecting = false
                self.projectionTask = nil
                self.message = error.localizedDescription
                onComplete(nil)
            }
        }
    }

    /// Started requests follow the same completion/cancellation contract as navigation.
    func search(_ request: TextSearchRequest, sources: BibleSources, loadMore: Bool = false,
                onComplete: @escaping @MainActor (Result<SearchPage, Error>) -> Void = { _ in }) {
        let previous = loadMore && searchPage?.request == request && searchPage?.sources == sources ? searchPage : nil
        guard !loadMore || previous?.hasMore == true else { return }
        let id = begin()
        if !loadMore { searchPage = nil }
        searchRequest = request
        let (primary, secondary) = databases(sources)
        task = Task { [weak self] in
            do {
                let page = try await Self.loadSearchPage(request, sources: sources, primary: primary, secondary: secondary, after: previous?.cursor)
                guard let self, self.current(id) else { return }
                let result = SearchPage(id: previous?.id ?? page.id, request: request, sources: sources,
                                        hits: (previous?.hits ?? []) + page.hits, hasMore: page.hasMore)
                self.searchPage = result
                self.isLoading = false
                self.task = nil
                onComplete(.success(result))
            } catch {
                guard let self, self.current(id) else { return }
                self.isLoading = false
                self.task = nil
                self.message = error.localizedDescription
                onComplete(.failure(error))
            }
        }
    }

    nonisolated static func loadSearchPage(_ request: TextSearchRequest, sources: BibleSources,
                                          primary: any BibleReading, secondary: (any BibleReading)?,
                                          after: VerseCoordinate? = nil, pageSize: Int = 100) async throws -> SearchPage {
        async let first = primary.search(request, after: after, limit: pageSize + 1)
        async let second = secondary?.search(request, after: after, limit: pageSize + 1)
        let (primaryMatches, secondaryMatches) = try await (first, second ?? [])
        let matches = try LoadedChapter.merge(primary: primaryMatches, secondary: secondaryMatches)
        let references = matches.prefix(pageSize).map(\.reference)
        async let primaryText = primary.verses(references)
        async let secondaryText = secondary?.verses(references)
        let pairs = try await LoadedChapter.merge(primary: primaryText, secondary: secondaryText ?? [])
        let firstIDs = Set(primaryMatches.map(\.id)), secondIDs = Set(secondaryMatches.map(\.id))
        let hits = pairs.map { SearchHit(pair: $0, matchedPrimary: firstIDs.contains($0.id), matchedSecondary: secondIDs.contains($0.id)) }
        return SearchPage(request: request, sources: sources, hits: hits, hasMore: matches.count > pageSize)
    }
}
