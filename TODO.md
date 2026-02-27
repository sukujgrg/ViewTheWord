# TODO

- Projection update path: keep projector content updates immediate (`VerseRowView` -> `MainView` -> `ProjectorViewModel`) for arrow-key navigation responsiveness.
- Network mirror path: add debounce/throttle only around `sendTextOverNetwork(...)` in `ProjectorView` to avoid flooding external display/API updates during rapid verse navigation.

## Performance Improvements

### High Priority

- [x] **Cache `BibleUrl.getAvailableBibleUrls()` results** — `Db.swift`
  - **Why:** `BibleUrl.init()` calls `getAvailableBibleUrls()` 3 times (once directly, once per `getBibleUrl()` call). Each call does `FileManager.contentsOfDirectory` + regex validation + deduplication. This constructor is invoked from `MainView.init()`, `VerseRowView.refreshAvailableBibles()`, and `BibleImportView.refreshAvailableBibles()`.
  - **Change:** Compute `getAvailableBibleUrls()` once in `BibleUrl.init()`, store it as a property, and reuse it in `getBibleUrl()`. For cross-view sharing, pass the URL list around or use a shared cache invalidated only on bible import.
  - **Expected improvement:** Eliminates ~3x redundant filesystem scans per `BibleUrl` construction. Noticeable on slower disks or when documents directory has many files.

- [x] **`BookmarkStore.contains()` — O(n) linear scan called per visible row per render** — `AppConstants.swift:384`
  - **Why:** `contains()` creates a temporary `Entry`, extracts its `id`, then linear-scans `entries`. This is called from `VerseRowView.verseRow()` for every visible row (~30 rows) on every render. With up to 200 bookmarks, that's ~6000 string comparisons per render cycle.
  - **Change:** Maintain a `private var bookmarkIDs: Set<String>` alongside `entries`, updated in `add()`, `remove()`, `clear()`, and `load()`. Change `contains()` to `bookmarkIDs.contains(Entry(reference: reference).id)`.
  - **Expected improvement:** Per-row bookmark check drops from O(n) to O(1). Measurable improvement when scrolling through verses with a large bookmark list.

- [x] **`HistoryStore.groupedSections` recomputed on every access** — `AppConstants.swift:142`
  - **Why:** `groupedSections` is a computed property that sorts entries, groups by week, and creates labels. It's read from `ChaptersListView`'s body, so it runs on every SwiftUI render pass. The work includes date arithmetic, sorting, and array allocation.
  - **Change:** Make `groupedSections` a `@Published private(set)` property. Recompute it inside `append()`, `clear()`, and `load()` after `entries` changes.
  - **Expected improvement:** Eliminates redundant sort/group/allocate on every render. Only recomputes when history actually changes. Reduces per-render overhead in the chapter column.

### Medium Priority

- [x] **`NSRegularExpression` compiled on every verse query parse** — `RxVerse.swift:288`
  - **Why:** `formatVerseAsk()` calls `NSRegularExpression(pattern:options:)` on every invocation. This runs on every text-field submit and every sidebar chapter click. The regex pattern is a constant string.
  - **Change:** Move the regex to a `private static let` on `SearchQuery` (or a file-level `let`), compiled once at app launch.
  - **Expected improvement:** Eliminates regex compilation overhead per query. Small but measurable — regex compilation involves pattern parsing and NFA construction.

- [x] **`onChange` with computed array values causes per-render allocation** — `ContentView.swift:381,446`
  - **Why:** `.onChange(of: bookmarkEntries.map(\.id))` and `.onChange(of: historySections.flatMap(\.items).map(\.id))` allocate new arrays on every body evaluation just so SwiftUI can check equality. The second one is especially expensive (flatMap + map + element-wise comparison).
  - **Change:** Add a simple version counter (`@Published private(set) var version: Int`) to `BookmarkStore` and `HistoryStore`, incremented on each mutation. Use `.onChange(of: bookmarkStore.entries.count)` or the version counter instead.
  - **Expected improvement:** Replaces O(n) array allocation + comparison with O(1) integer comparison per render pass. Reduces GC pressure from temporary arrays.

- [x] **No SQLite prepared statement caching for hot-path queries** — `Db.swift`
  - **Why:** `pickAVerseUnlocked`, `pickAChapterUnlocked`, and `searchTextUnlocked` each call `sqlite3_prepare_v2` + `sqlite3_finalize` on every invocation. Statement preparation involves SQL parsing and query planning. The correct pattern already exists in `getVersesUnlocked()` (line 679) which prepares once and reuses with `sqlite3_reset`/`sqlite3_clear_bindings`.
  - **Change:** Cache prepared statements as `OpaquePointer?` properties on `Bible` for the 2-3 most frequently called queries (verse lookup, chapter lookup). Use `sqlite3_reset` + `sqlite3_clear_bindings` between calls. Finalize in `closeDb()`.
  - **Expected improvement:** Eliminates SQL parse + query plan overhead per query. Meaningful during rapid verse navigation (arrow keys) where verse lookup runs on every keypress.

- [x] **Redundant `rebuildChapterRows` on `showOnlyPrimary` toggle** — `ContentView.swift:1065` + `VerseRowView.swift:354`
  - **Why:** When `showOnlyPrimary` changes, `MainView` calls `processSearchQuery` which re-fetches data and updates `verseRowViewModel.verseRowData`. This triggers `onChange(of: verseRowData.id)` in `VerseRowView` which calls `rebuildChapterRows()`. But `VerseRowView` also has its own `onChange(of: showOnlyPrimary)` that calls `rebuildChapterRows()` independently — so the rows are rebuilt twice.
  - **Change:** Remove the `onChange(of: showOnlyPrimary)` handler in `VerseRowView` (line 354-358). The rebuild is already handled by the `onChange(of: verseRowData.id)` path.
  - **Expected improvement:** Eliminates one redundant chapter row rebuild + scroll reset per toggle. Minor but avoids double work and potential visual flicker.

### Low Priority

- [x] **Linear verse lookup in `MainView.projectVerseFromRow`** — `ContentView.swift:1375-1381`
  - **Why:** `primaryVerseForNumber()` and `secondaryVerseForNumber()` use `.first(where:)` — O(n) linear scan. `VerseRowView` already solved this with `chapterRowIndexByVerseNumber` dictionary for O(1) lookups, but `MainView` still uses the slow path.
  - **Change:** Build a `[Int: AVerse]` dictionary (keyed by verse number) when chapter data is loaded, and use dictionary lookup instead of `.first(where:)`.
  - **Expected improvement:** Verse lookup drops from O(n) to O(1). Only noticeable in very long chapters (Psalm 119 = 176 verses) during rapid keyboard navigation.

- [x] **`AVerse` not `Identifiable` — index-based SwiftUI diffing** — `Db.swift:4` + `ContentView.swift:505`
  - **Why:** `SearchResultsView` uses `ForEach(primaryResults.indices, id: \.self)` because `AVerse` doesn't conform to `Identifiable`. Index-based identity means SwiftUI can't efficiently diff when search results change — it must rebuild all rows even if most results are the same.
  - **Change:** Add `Identifiable` conformance to `AVerse` with `var id: Int { verseId }`. Update `ForEach` calls to use the conformance directly.
  - **Expected improvement:** Enables SwiftUI to skip rebuilding unchanged search result rows. Noticeable when search results are large (100 items) and the user switches between similar queries.

- [ ] **6 LIKE clauses per search term in word search** — `RxVerse.swift:42-65`
  - **Why:** Each search term in `SearchExpression.toSQL()` generates 6 `LIKE ?` clauses for word-boundary matching. A query like `jesus AND mary AND love` produces 18 LIKE clauses, each requiring a full table scan in SQLite.
  - **Change:** Use a single `LIKE '%term%'` per term in SQL, then post-filter results in Swift for word-boundary matching. Or consider SQLite FTS (Full Text Search) extension for proper full-text indexing.
  - **Expected improvement:** Reduces SQL complexity by ~6x per term. Post-filtering in Swift is fast since the result set is already limited to 100 rows. FTS would give order-of-magnitude improvement for large bibles but requires schema changes.
