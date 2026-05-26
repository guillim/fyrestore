import SwiftUI
import AppKit

/// An error tied to a UI region, with the action needed to recover.
/// The retry kind is an enum so it's safely Equatable; the view layer dispatches.
enum RetryKind: Equatable {
    case loadProjects
    case loadDatabases
    case loadCollections
    case loadDocuments
}

/// Optional second action offered alongside Retry. Used when "retrying the same
/// operation" isn't the obvious recovery — e.g. a broken project pick where the
/// user is really just looking for a way back to the picker.
enum AlternativeAction: Equatable {
    case pickAnotherProject

    var label: String {
        switch self {
        case .pickAnotherProject: return "Pick another project"
        }
    }
}

struct ContextualError: Equatable {
    let message: String
    let retry: RetryKind
    var alternative: AlternativeAction? = nil
}

@MainActor
final class BrowserModel: ObservableObject {
    @Published var projects: [GCPProject] = []
    @Published var selectedProject: GCPProject?
    @Published var databases: [FirestoreDatabase] = []
    @Published var selectedDatabase: FirestoreDatabase?
    @Published var collections: [String] = []

    @Published var currentPath: FirestorePath?
    @Published var documents: [FirestoreDocument] = []
    @Published var nextPageToken: String?
    @Published var selectedDocument: FirestoreDocument?

    /// How many documents have been fetched from Firestore so far at the current path.
    /// For client-side filters this is the denominator in "X of Y scanned" — it grows
    /// each time the user clicks "Load more". For server-side filters / unfiltered
    /// listings it tracks the same number as `documents.count`.
    @Published var scannedCount: Int = 0

    /// Whether the current query is reading every match Firestore would return for the
    /// given filter — i.e. an authoritative answer (server-side). False means matches
    /// are restricted to the documents already paginated into memory.
    var isExhaustiveResult: Bool {
        guard let f = appliedFilter else { return nextPageToken == nil }
        return f.op.isServerSide
    }

    /// Sub-collections under the currently selected document.
    @Published var subcollections: [String] = []
    @Published var loadingSubcollections = false
    private var subcollectionsLoadedFor: String?

    /// Filter UI mode. Basic = field + operator + value pickers. Advanced = the
    /// `field op value` free-text expression. Both compile to the same QueryFilter.
    enum FilterMode { case basic, advanced }
    @Published var filterMode: FilterMode = .basic

    /// Basic-mode inputs.
    @Published var basicField: String = ""
    @Published var basicOp: QueryFilter.Op = .equal
    @Published var basicValue: String = ""

    /// Advanced-mode free-text expression.
    @Published var filterText: String = ""

    /// The filter that's actually applied to the current document list (compiled from
    /// whichever mode is active when the user submits).
    @Published var appliedFilter: QueryFilter?
    @Published var filterError: String?

    @Published var loadingProjects = false
    @Published var loadingCollections = false
    @Published var loadingDocuments = false
    @Published var loadingMore = false

    /// Errors are surfaced in the pane that produced them, not in a global strip.
    /// Each one carries a retry action so the user has a single click out of the failure.
    @Published var sidebarError: ContextualError?
    @Published var documentListError: ContextualError?
    /// Legacy single-error slot, kept for compatibility with code that hasn't been split.
    /// Set to nil when refactor is complete.
    @Published var error: String?

    let client: FirestoreClient

    init(session: Session) {
        self.client = FirestoreClient(session: session)
    }

    // MARK: - Projects / databases

    func loadProjects() async {
        loadingProjects = true
        defer { loadingProjects = false }
        do {
            projects = try await client.listProjects()
            sidebarError = nil
        } catch {
            sidebarError = ContextualError(message: describe(error), retry: .loadProjects)
        }
    }

    /// Re-fetches everything from scratch: project list, databases, collections,
    /// and the documents at the current path. Triggered by the sidebar's ↻ button.
    func refreshAll() async {
        sidebarError = nil
        documentListError = nil
        error = nil
        await loadProjects()
        if let p = selectedProject {
            // Re-fetch databases & collections for the still-selected project, but
            // preserve the user's current path / selection / filter where possible.
            do {
                let dbs = try await client.listDatabases(projectId: p.projectId)
                databases = dbs
                if let d = selectedDatabase ?? dbs.first(where: { $0.databaseId == "(default)" }) ?? dbs.first {
                    selectedDatabase = d
                    collections = try await client.listRootCollections(projectId: p.projectId, databaseId: d.databaseId)
                } else {
                    selectedDatabase = nil
                    collections = []
                    resetCollectionState()
                }
            } catch {
                sidebarError = ContextualError(
                    message: describe(error),
                    retry: .loadCollections,
                    alternative: .pickAnotherProject
                )
                collections = []
                resetCollectionState()
            }
            if currentPath != nil {
                await reloadCurrentPath()
            }
        }
    }

    /// Dispatch an alternative-action button click on an error banner.
    /// Currently the only one is "pick another project" — which clears the broken
    /// selection so the project dropdown becomes the obvious next step.
    func handleAlternative(_ action: AlternativeAction) async {
        switch action {
        case .pickAnotherProject:
            sidebarError = nil
            documentListError = nil
            selectedProject = nil
            databases = []
            selectedDatabase = nil
            collections = []
            resetCollectionState()
        }
    }

    /// Dispatch a retry button click. Each `RetryKind` maps to the right reload path.
    func retry(_ kind: RetryKind) async {
        switch kind {
        case .loadProjects:
            sidebarError = nil
            await loadProjects()
        case .loadDatabases:
            sidebarError = nil
            if let p = selectedProject { await selectProject(p) }
        case .loadCollections:
            sidebarError = nil
            if let d = selectedDatabase { await selectDatabase(d) }
        case .loadDocuments:
            documentListError = nil
            await reloadCurrentPath()
        }
    }

    func selectProject(_ p: GCPProject) async {
        selectedProject = p
        databases = []
        selectedDatabase = nil
        collections = []
        sidebarError = nil
        documentListError = nil
        error = nil
        resetCollectionState()
        do {
            let dbs = try await client.listDatabases(projectId: p.projectId)
            databases = dbs
            if let first = dbs.first(where: { $0.databaseId == "(default)" }) ?? dbs.first {
                await selectDatabase(first)
            }
            // If dbs is empty, the project simply has no Firestore database.
            // collections stays [], sidebar shows the empty-state message.
        } catch {
            sidebarError = ContextualError(
                message: describe(error),
                retry: .loadDatabases,
                alternative: .pickAnotherProject
            )
        }
    }

    func selectDatabase(_ d: FirestoreDatabase) async {
        selectedDatabase = d
        resetCollectionState()
        collections = []
        guard let p = selectedProject else { return }
        loadingCollections = true
        defer { loadingCollections = false }
        do {
            collections = try await client.listRootCollections(projectId: p.projectId, databaseId: d.databaseId)
            sidebarError = nil
        } catch {
            sidebarError = ContextualError(
                message: describe(error),
                retry: .loadCollections,
                alternative: .pickAnotherProject
            )
        }
    }

    private func resetCollectionState() {
        currentPath = nil
        documents = []
        nextPageToken = nil
        scannedCount = 0
        selectedDocument = nil
        subcollections = []
        subcollectionsLoadedFor = nil
        filterText = ""
        basicField = ""
        basicValue = ""
        basicOp = .equal
        appliedFilter = nil
        filterError = nil
    }

    // MARK: - Navigation

    func enterRootCollection(_ name: String) async {
        guard let p = selectedProject, let d = selectedDatabase else { return }
        let path = FirestorePath.root(projectId: p.projectId, databaseId: d.databaseId, collection: name)
        await enter(path: path)
    }

    func enterSubcollection(under doc: FirestoreDocument, name: String) async {
        guard let path = currentPath else { return }
        guard let docId = doc.name.split(separator: "/").last.map(String.init) else { return }
        let next = path.appending(document: docId, subcollection: name)
        await enter(path: next)
    }

    /// Navigate to a document by its full Firestore resource name, e.g.
    /// `projects/X/databases/(default)/documents/users/alice/orders/123`.
    /// Loads the parent collection, then selects the doc by short id.
    func navigateToReference(_ ref: String) async {
        let parts = ref.split(separator: "/").map(String.init)
        guard parts.count >= 7,
              parts[0] == "projects",
              parts[2] == "databases",
              parts[4] == "documents" else {
            documentListError = ContextualError(
                message: "Cannot parse reference: \(ref)",
                retry: .loadDocuments)
            return
        }
        let projectId = parts[1]
        let databaseId = parts[3]
        let docPath = Array(parts[5...])

        guard docPath.count >= 2, docPath.count % 2 == 0 else {
            documentListError = ContextualError(
                message: "Reference path is malformed.",
                retry: .loadDocuments)
            return
        }

        guard let p = selectedProject, p.projectId == projectId else {
            documentListError = ContextualError(
                message: "Reference points to a different project (\(projectId)). Cross-project navigation isn't supported.",
                retry: .loadDocuments)
            return
        }
        guard let d = selectedDatabase, d.databaseId == databaseId else {
            documentListError = ContextualError(
                message: "Reference points to a different database (\(databaseId)).",
                retry: .loadDocuments)
            return
        }

        let targetDocId = docPath.last!

        var segments: [PathSegment] = []
        // docPath is pairs of [collection, document]. We want the path up through the
        // collection that *contains* the target doc, then select that doc.
        for i in stride(from: 0, to: docPath.count - 1, by: 2) {
            segments.append(.collection(docPath[i]))
            if i + 1 < docPath.count - 1 {
                segments.append(.document(docPath[i + 1]))
            }
        }

        let targetPath = FirestorePath(
            projectId: projectId,
            databaseId: databaseId,
            segments: segments)
        await enter(path: targetPath)

        if let target = documents.first(where: { $0.shortId == targetDocId }) {
            selectedDocument = target
            await refreshSubcollectionsForSelection()
        } else {
            documentListError = ContextualError(
                message: "Document '\(targetDocId)' isn't in the first 100 results. Click Load more or filter to find it.",
                retry: .loadDocuments)
        }
    }

    /// Used by the breadcrumb when the user clicks a `.document` segment. The
    /// segment at `segmentIndex` is the document; we navigate to its parent
    /// collection (segmentIndex of the collection) and then select the doc.
    func navigateToDocument(atSegmentIndex segmentIndex: Int) async {
        guard let path = currentPath else { return }
        guard segmentIndex < path.segments.count,
              case .document(let docId) = path.segments[segmentIndex] else { return }
        // The parent collection is at segmentIndex - 1; depth (1-based count of segments)
        // to truncate to is segmentIndex (so we keep segments [0 ..< segmentIndex]).
        let truncated = path.prefix(segmentIndex)
        guard !truncated.collectionId.isEmpty else { return }
        await enter(path: truncated)
        if let target = documents.first(where: { $0.shortId == docId }) {
            selectedDocument = target
            await refreshSubcollectionsForSelection()
        }
    }

    func navigateTo(depth: Int) async {
        guard let path = currentPath else { return }
        // depth is segment index (1-based) of the collection to land on.
        let truncated = path.prefix(depth)
        guard truncated.collectionId.isEmpty == false else { return }
        await enter(path: truncated)
    }

    private func enter(path: FirestorePath) async {
        currentPath = path
        documents = []
        nextPageToken = nil
        scannedCount = 0
        selectedDocument = nil
        subcollections = []
        subcollectionsLoadedFor = nil
        filterText = ""
        basicField = ""
        basicValue = ""
        basicOp = .equal
        appliedFilter = nil
        filterError = nil
        await reloadCurrentPath()
    }

    // MARK: - Document loading

    func reloadCurrentPath() async {
        guard let path = currentPath else { return }
        loadingDocuments = true
        defer { loadingDocuments = false }
        do {
            if let filter = appliedFilter, filter.op.isServerSide {
                let docs = try await client.runQuery(at: path, filter: filter)
                documents = docs
                nextPageToken = nil
                scannedCount = docs.count
            } else {
                let page = try await client.listDocuments(at: path)
                if let filter = appliedFilter {
                    documents = page.documents.filter { $0.matches(filter) }
                } else {
                    documents = page.documents
                }
                nextPageToken = page.nextPageToken
                scannedCount = page.documents.count
            }
            selectedDocument = documents.first
            documentListError = nil
            await refreshSubcollectionsForSelection()
        } catch {
            documentListError = ContextualError(message: describe(error), retry: .loadDocuments)
        }
    }

    func loadMore() async {
        guard let path = currentPath,
              let token = nextPageToken,
              !loadingMore else { return }
        // Server-side filters use `runQuery` which doesn't paginate via pageToken,
        // so loading more there is meaningless. Client-side filters (contains) do
        // paginate; we just filter each new page locally.
        if appliedFilter?.op.isServerSide == true { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await client.listDocuments(at: path, pageToken: token)
            let newDocs: [FirestoreDocument]
            if let filter = appliedFilter {
                newDocs = page.documents.filter { $0.matches(filter) }
            } else {
                newDocs = page.documents
            }
            documents.append(contentsOf: newDocs)
            nextPageToken = page.nextPageToken
            scannedCount += page.documents.count
        } catch {
            documentListError = ContextualError(message: describe(error), retry: .loadDocuments)
        }
    }

    // MARK: - Filter

    func applyFilter() async {
        filterError = nil
        do {
            let parsed: QueryFilter?
            switch filterMode {
            case .basic:
                parsed = try QueryFilter.build(field: basicField, op: basicOp, rawValue: basicValue)
            case .advanced:
                parsed = try QueryFilter.parse(filterText)
            }
            appliedFilter = parsed
            await reloadCurrentPath()
        } catch {
            filterError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearFilter() async {
        filterText = ""
        basicField = ""
        basicValue = ""
        basicOp = .equal
        filterError = nil
        guard appliedFilter != nil else { return }
        appliedFilter = nil
        await reloadCurrentPath()
    }

    /// Toggle between basic and advanced modes. Mirror the inputs across the boundary
    /// so the user can keep iterating without losing what they typed.
    func toggleFilterMode() {
        switch filterMode {
        case .basic:
            // Going basic → advanced: pre-fill the text expression with whatever the
            // basic fields say (even if not yet applied).
            let f = basicField.trimmingCharacters(in: .whitespaces)
            let v = basicValue.trimmingCharacters(in: .whitespaces)
            if !f.isEmpty || !v.isEmpty {
                filterText = "\(f) \(basicOp.symbol) \(v)".trimmingCharacters(in: .whitespaces)
            }
            filterMode = .advanced
        case .advanced:
            // Going advanced → basic: try to parse the expression to populate the
            // three pickers. Silently ignore parse failures — user just sees blanks.
            if let parsed = try? QueryFilter.parse(filterText) {
                basicField = parsed.field
                basicOp = parsed.op
                basicValue = rawValueDisplay(parsed.value)
            }
            filterMode = .basic
        }
        filterError = nil
    }

    private func rawValueDisplay(_ v: QueryFilter.Value) -> String {
        switch v {
        case .string(let s): return s
        case .integer(let i): return String(i)
        case .double(let d): return String(d)
        case .boolean(let b): return b ? "true" : "false"
        }
    }

    // MARK: - Selection / sub-collections

    func selectDocument(_ doc: FirestoreDocument) async {
        selectedDocument = doc
        await refreshSubcollectionsForSelection()
    }

    private func refreshSubcollectionsForSelection() async {
        guard let doc = selectedDocument else {
            subcollections = []
            subcollectionsLoadedFor = nil
            return
        }
        if subcollectionsLoadedFor == doc.name { return }
        subcollectionsLoadedFor = doc.name
        loadingSubcollections = true
        defer { loadingSubcollections = false }
        do {
            let ids = try await client.listDocumentSubcollections(documentResourceName: doc.name)
            // Guard against stale responses if user changed selection while loading.
            if selectedDocument?.name == doc.name {
                subcollections = ids
            }
        } catch {
            // Surface but don't blow up — listCollectionIds requires extra permission.
            if selectedDocument?.name == doc.name {
                subcollections = []
            }
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

struct MainView: View {
    @EnvironmentObject var session: Session
    @StateObject private var model: BrowserModel

    @AppStorage("fyrestore.sidebarWidth") private var sidebarWidth: Double = 280
    @AppStorage("fyrestore.documentListWidth") private var documentListWidth: Double = 340
    @AppStorage("fyrestore.lastProjectId") private var lastProjectId: String = ""

    /// Per-document field-name filter. Resets on doc selection change.
    @State private var fieldSearch: String = ""

    init(session: Session) {
        _model = StateObject(wrappedValue: BrowserModel(session: session))
    }

    /// Union of all top-level field names from the currently-loaded documents.
    /// Used to populate the basic filter's field dropdown so users don't have to
    /// remember field names.
    private var availableFieldNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for doc in model.documents {
            for f in doc.fields where !seen.contains(f.name) {
                seen.insert(f.name)
                out.append(f.name)
            }
        }
        return out.sorted()
    }

    /// Hide the right-most pane entirely when there's nothing meaningful to show.
    /// Errors now surface in the pane where they happened, so they don't keep this open.
    private var detailPaneVisible: Bool {
        model.selectedDocument != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarWidth)
            ResizeHandle(width: $sidebarWidth, lower: 220, upper: 500)
            if detailPaneVisible {
                documentList
                    .frame(width: documentListWidth)
                ResizeHandle(width: $documentListWidth, lower: 260, upper: 700)
                documentDetail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                documentList
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.bg)
        .task {
            if model.projects.isEmpty { await model.loadProjects() }
            if model.selectedProject == nil {
                let target = model.projects.first(where: { $0.projectId == lastProjectId })
                    ?? model.projects.first
                if let target = target {
                    await model.selectProject(target)
                }
            }
        }
        .onChange(of: model.selectedProject?.projectId ?? "") { newId in
            if !newId.isEmpty { lastProjectId = newId }
        }
        .onChange(of: model.selectedDocument?.name ?? "") { _ in
            fieldSearch = ""
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            if model.databases.count > 1 {
                databasePickerRow
            }
            collectionsList
            if let err = model.sidebarError {
                errorBanner(err, onDismiss: { model.sidebarError = nil })
            }
        }
        .background(Theme.panel.opacity(0.6))
    }

    private var sidebarHeader: some View {
        VStack(spacing: 0) {
            // Top row: account + sign-out menu on the right.
            HStack(spacing: 6) {
                Text(session.userEmail ?? "Signed in")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                Spacer()
                Menu {
                    Button("Sign out", action: { session.signOut() })
                } label: {
                    Image(systemName: "person.circle")
                        .foregroundStyle(Theme.textMuted)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            // Project picker row.
            HStack(spacing: 6) {
                projectPicker
                Button {
                    Task { await model.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Refresh projects and collections")
                .disabled(model.loadingProjects)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)
    }

    private var projectPicker: some View {
        Menu {
            if model.loadingProjects {
                Text("Loading projects…")
            } else if model.projects.isEmpty {
                Text("No projects available")
            } else {
                ForEach(model.projects) { p in
                    Button {
                        Task { await model.selectProject(p) }
                    } label: {
                        if p.projectId == model.selectedProject?.projectId {
                            Label(p.name.isEmpty ? p.projectId : p.name, systemImage: "checkmark")
                        } else {
                            Text(p.name.isEmpty ? p.projectId : p.name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                if let p = model.selectedProject {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name.isEmpty ? p.projectId : p.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(p.projectId)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                } else {
                    Text(model.loadingProjects ? "Loading…" : "Choose project…")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.bg)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Theme.divider, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
    }

    private var databasePickerRow: some View {
        HStack(spacing: 6) {
            Text("Database")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
            Picker("", selection: Binding(
                get: { model.selectedDatabase?.databaseId ?? "(default)" },
                set: { newId in
                    if let d = model.databases.first(where: { $0.databaseId == newId }) {
                        Task { await model.selectDatabase(d) }
                    }
                }
            )) {
                ForEach(model.databases) { d in
                    Text(d.databaseId).tag(d.databaseId)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)
    }

    private var collectionsList: some View {
        Group {
            if model.selectedProject == nil {
                emptyState("Pick a project above.")
            } else if model.loadingCollections {
                VStack {
                    ProgressView().padding()
                    Spacer()
                }
            } else if model.databases.isEmpty {
                emptyState("This project has no Firestore database, or the Firestore API isn't enabled on it.")
            } else if model.collections.isEmpty {
                emptyState("This database has no collections.")
            } else {
                _collectionRowsScroll
            }
        }
    }

    private var _collectionRowsScroll: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.collections, id: \.self) { c in
                    Button {
                        Task { await model.enterRootCollection(c) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                            Text(c)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(isSelectedRootCollection(c) ? Theme.divider.opacity(0.7) : Color.clear)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                }
            }
        }
    }

    private func isSelectedRootCollection(_ c: String) -> Bool {
        guard let path = model.currentPath else { return false }
        return path.isRootCollection && path.collectionId == c
    }

    // MARK: Document list

    private var documentList: some View {
        VStack(spacing: 0) {
            documentListHeader

            if let err = model.documentListError {
                errorBanner(err, onDismiss: { model.documentListError = nil })
            }

            if model.loadingDocuments && model.documents.isEmpty {
                ProgressView().padding()
                Spacer()
            } else if model.currentPath == nil {
                emptyState("Pick a collection on the left.")
            } else if model.documents.isEmpty && model.documentListError == nil {
                emptyState(model.appliedFilter != nil ? "No documents match this filter." : "No documents.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.documents) { doc in
                            documentRow(doc)
                            Divider().background(Theme.divider)
                        }
                        loadMoreFooter
                    }
                }
            }
        }
        .background(Theme.panel.opacity(0.3))
    }

    private var documentListHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if let path = model.currentPath {
                    breadcrumb(for: path)
                } else {
                    Text("Documents")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Text(documentCountLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)

            if model.currentPath != nil {
                filterBar
            }
        }
    }

    private var documentCountLabel: String {
        guard model.currentPath != nil else { return "" }
        let n = model.documents.count
        if let filter = model.appliedFilter {
            if filter.op.isServerSide {
                // runQuery currently caps at 100; flag potential overflow.
                return n >= 100 ? "100+ matches" : "\(n) match\(n == 1 ? "" : "es")"
            } else {
                return "\(n) of \(model.scannedCount) scanned"
            }
        }
        if model.nextPageToken != nil {
            return "\(n) shown · more"
        }
        return "\(n) shown"
    }

    private func breadcrumb(for path: FirestorePath) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(path.segments.enumerated()), id: \.offset) { item in
                if item.offset > 0 {
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                switch item.element {
                case .collection(let id):
                    // Trailing collection (where we currently are) is non-clickable.
                    if item.offset == path.segments.count - 1 {
                        Text(id)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.textPrimary)
                    } else {
                        Button {
                            Task { await model.navigateTo(depth: item.offset + 1) }
                        } label: {
                            Text(id)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                case .document(let id):
                    // Click navigates to the collection containing this document, then
                    // selects the document.
                    Button {
                        Task { await model.navigateToDocument(atSegmentIndex: item.offset) }
                    } label: {
                        Text(id)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open this document")
                }
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 6) {
            switch model.filterMode {
            case .basic:
                basicFilterRow
            case .advanced:
                advancedFilterRow
            }

            HStack(spacing: 8) {
                Button {
                    model.toggleFilterMode()
                } label: {
                    Text(model.filterMode == .basic ? "Advanced" : "Basic")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help(model.filterMode == .basic ? "Switch to free-text expression" : "Switch to guided fields")

                if let err = model.filterError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }

                Spacer()

                filterStatusBadge
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(Theme.bg)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)
    }

    private var basicFilterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)

            fieldComboInput
                .frame(maxWidth: .infinity)

            Picker("", selection: $model.basicOp) {
                ForEach(QueryFilter.Op.allCases, id: \.self) { op in
                    Text(op.symbol).tag(op)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(width: 90)

            TextField("value", text: $model.basicValue)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .frame(maxWidth: .infinity)
                .onSubmit { Task { await model.applyFilter() } }

            if hasFilterInput {
                Button {
                    Task { await model.clearFilter() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
    }

    /// Pure dropdown for the field name (no free-text). Lists every field name found
    /// in the currently-loaded documents.
    private var fieldComboInput: some View {
        Menu {
            if availableFieldNames.isEmpty {
                Text("No fields loaded yet")
            } else {
                ForEach(availableFieldNames, id: \.self) { name in
                    Button {
                        model.basicField = name
                    } label: {
                        if name == model.basicField {
                            Label(name, systemImage: "checkmark")
                        } else {
                            Text(name)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(model.basicField.isEmpty ? "Pick field" : model.basicField)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(model.basicField.isEmpty ? Theme.textMuted : Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.divider, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(availableFieldNames.isEmpty
              ? "Open a collection to see field options"
              : "Pick from \(availableFieldNames.count) field\(availableFieldNames.count == 1 ? "" : "s")")
    }

    private var advancedFilterRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            TextField("field == value", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { Task { await model.applyFilter() } }
            if hasFilterInput {
                Button {
                    Task { await model.clearFilter() }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var filterStatusBadge: some View {
        if let filter = model.appliedFilter {
            HStack(spacing: 4) {
                Circle()
                    .fill(filter.op.isServerSide ? Color.green : Color.orange)
                    .frame(width: 6, height: 6)
                Text(filterStatusText(filter: filter))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textMuted)
            }
            .help(filter.op.isServerSide
                  ? "Server-side query — Firestore returned every match (capped at 100 in this build)."
                  : "Local scan — only documents already loaded are checked. Click \"Load more\" to scan further pages.")
        }
    }

    private func filterStatusText(filter: QueryFilter) -> String {
        if filter.op.isServerSide {
            let n = model.documents.count
            return n >= 100 ? "server · 100+ matches" : "server · \(n) match\(n == 1 ? "" : "es")"
        } else {
            return "local scan · \(model.documents.count) of \(model.scannedCount)"
        }
    }

    private var hasFilterInput: Bool {
        model.appliedFilter != nil
            || !model.filterText.isEmpty
            || !model.basicField.isEmpty
            || !model.basicValue.isEmpty
    }

    /// One row in the document list. Whole row (including padding/spacer area) is
    /// clickable, not just the rendered text. Preview subtitle uses smart field picks.
    private func documentRow(_ doc: FirestoreDocument) -> some View {
        let consoleURL = firebaseConsoleURL(for: doc)
        return Button {
            Task { await model.selectDocument(doc) }
        } label: {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(doc.shortId)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(documentPreviewSubtitle(doc))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(model.selectedDocument == doc ? Theme.divider.opacity(0.7) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy as JSON") { Clipboard.setString(doc.prettyJSON()) }
            Button("Copy reference path") { Clipboard.setString(doc.name) }
            if let url = consoleURL {
                Button("Open in Firebase Console") { NSWorkspace.shared.open(url) }
            }
            Divider()
            Button("Refresh") {
                Task { await model.reloadCurrentPath() }
            }
        }
    }

    private func documentPreviewSubtitle(_ doc: FirestoreDocument) -> String {
        let picks = doc.previewFields(limit: 2)
        if picks.isEmpty { return "—" }
        return picks.map { "\($0.name): \($0.value.preview)" }.joined(separator: " · ")
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if model.nextPageToken != nil && model.appliedFilter?.op.isServerSide != true {
            Button {
                Task { await model.loadMore() }
            } label: {
                HStack {
                    Spacer()
                    if model.loadingMore {
                        ProgressView().controlSize(.small)
                    }
                    Text(model.loadingMore ? "Loading…" : "Load more")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(model.loadingMore)
        }
    }

    // MARK: Document detail

    private var documentDetail: some View {
        VStack(spacing: 0) {
            if let doc = model.selectedDocument {
                DocumentDetailHeader(
                    doc: doc,
                    fieldSearch: $fieldSearch,
                    consoleURL: firebaseConsoleURL(for: doc)
                )
                ScrollView {
                    VStack(spacing: 0) {
                        let visibleFields = filteredFields(of: doc)
                        if visibleFields.isEmpty && !fieldSearch.isEmpty {
                            Text("No fields match \"\(fieldSearch)\".")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 30)
                        } else {
                            ForEach(Array(visibleFields.enumerated()), id: \.offset) { item in
                                FieldRow(name: item.element.name, value: item.element.value, depth: 0)
                                    .contextMenu {
                                        Button("Copy value") { Clipboard.setString(item.element.value.searchableString) }
                                        Button("Copy field name") { Clipboard.setString(item.element.name) }
                                        Button("Copy as JSON") { Clipboard.setString(item.element.value.prettyJSON()) }
                                    }
                                Divider().background(Theme.divider)
                            }
                        }
                        subcollectionsSection(for: doc)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                header(title: "Document", subtitle: nil)
                emptyState("Select a document to inspect its fields.")
            }
        }
        .background(Theme.panel)
        .environment(\.referenceNavigator) { ref in
            Task { await model.navigateToReference(ref) }
        }
    }

    private func filteredFields(of doc: FirestoreDocument) -> [FirestoreField] {
        guard !fieldSearch.isEmpty else { return doc.fields }
        let q = fieldSearch.lowercased()
        return doc.fields.filter { $0.name.lowercased().contains(q) }
    }

    private func firebaseConsoleURL(for doc: FirestoreDocument) -> URL? {
        guard let p = model.selectedProject, let d = model.selectedDatabase else { return nil }
        return FirebaseConsole.url(forDocumentName: doc.name, project: p.projectId, database: d.databaseId)
    }

    /// Banner shown in the pane where an error originated. Includes a Retry button
    /// (wired through the model's `retry(_:)`), an optional alternative action like
    /// "Pick another project", and a dismiss (×) button.
    private func errorBanner(_ err: ContextualError, onDismiss: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(err.message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    Button {
                        Task { await model.retry(err.retry) }
                    } label: {
                        Text("Retry")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                    .buttonStyle(.plain)
                    if let alt = err.alternative {
                        Button {
                            Task { await model.handleAlternative(alt) }
                        } label: {
                            Text(alt.label)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.red.opacity(0.06))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.red.opacity(0.2)), alignment: .top)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.red.opacity(0.2)), alignment: .bottom)
    }

    @ViewBuilder
    private func subcollectionsSection(for doc: FirestoreDocument) -> some View {
        if model.loadingSubcollections {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading sub-collections…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        } else if !model.subcollections.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Sub-collections")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textMuted)
                    .textCase(.uppercase)
                FlowChips(items: model.subcollections) { name in
                    Task { await model.enterSubcollection(under: doc, name: name) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: helpers

    private func header(title: String, subtitle: String? = nil, trailing: AnyView? = nil) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let s = subtitle {
                    Text(s)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let trailing = trailing { trailing }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)
    }

    private func emptyState(_ msg: String) -> some View {
        VStack {
            Spacer()
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Resizable divider between split panes

/// 6 px wide hit area with a 1 px visual line, drag-to-resize, and a left/right cursor
/// on hover. The bound `width` is the width of the pane **to the left** of this handle.
struct ResizeHandle: View {
    @Binding var width: Double
    let lower: Double
    let upper: Double

    @State private var startWidth: Double?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .frame(maxHeight: .infinity)
            .overlay(
                Rectangle()
                    .fill(Theme.divider)
                    .frame(width: 1)
            )
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if startWidth == nil { startWidth = width }
                        let proposed = (startWidth ?? width) + Double(value.translation.width)
                        width = min(upper, max(lower, proposed))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}

// MARK: - Document detail header (with copy-as-JSON button)

struct DocumentDetailHeader: View {
    let doc: FirestoreDocument
    @Binding var fieldSearch: String
    let consoleURL: URL?

    @State private var justCopied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(doc.shortId)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let updated = doc.updateTime {
                        Text("Updated \(humanize(updated))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                            .help(updated)
                    }
                }
                Spacer()
                if justCopied {
                    Text("Copied")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                        .transition(.opacity)
                }
                if let url = consoleURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Open this document in the Firebase Console")
                }
                Button(action: copyJSON) {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(justCopied ? Theme.accent : Theme.textMuted)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("Copy document as JSON")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Field-search row.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                TextField("Filter fields…", text: $fieldSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                if !fieldSearch.isEmpty {
                    Button { fieldSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .top)
        }
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Theme.divider), alignment: .bottom)
        .onChange(of: doc.id) { _ in justCopied = false }
        .contextMenu {
            Button("Copy document as JSON") {
                Clipboard.setString(doc.prettyJSON())
            }
            Button("Copy reference path") {
                Clipboard.setString(doc.name)
            }
            if let url = consoleURL {
                Button("Open in Firebase Console") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func humanize(_ iso: String) -> String {
        FirestoreValue.timestamp(iso).relativeTimestamp ?? iso
    }

    private func copyJSON() {
        Clipboard.setString(doc.prettyJSON())
        withAnimation(.easeInOut(duration: 0.15)) { justCopied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { justCopied = false }
            }
        }
    }
}

// MARK: - Sub-collection chips (wrapping row)

struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void

    var body: some View {
        // SwiftUI doesn't have a native flow layout pre-16; use a simple wrap by inserting
        // ChipRows. For our small lists (handful of sub-collections), a single HStack is fine.
        HStack(spacing: 6) {
            ForEach(items, id: \.self) { name in
                Button {
                    onTap(name)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text(name)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.typeChip)
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Field rendering

struct FieldRow: View {
    let name: String
    let value: FirestoreValue
    let depth: Int
    @State private var expanded = true
    @Environment(\.referenceNavigator) private var referenceNavigator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isExpandable {
                    Button {
                        expanded.toggle()
                    } label: {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.textMuted)
                            .frame(width: 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }

                Text(name)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)

                typeChip(for: value)

                if !isExpandable {
                    leafValueView
                } else {
                    Spacer()
                }
            }
            .padding(.leading, CGFloat(depth) * 14 + 14)
            .padding(.trailing, 14)
            .padding(.vertical, 6)

            if expanded {
                children
            }
        }
    }

    private var isExpandable: Bool {
        switch value {
        case .map(let m): return !m.isEmpty
        case .array(let a): return !a.isEmpty
        default: return false
        }
    }

    /// Rendering for the value text inside a leaf row. References become clickable
    /// links; timestamps render as relative time with absolute on hover.
    @ViewBuilder
    private var leafValueView: some View {
        Group {
            switch value {
            case .reference(let ref):
                Button {
                    referenceNavigator?(ref)
                } label: {
                    HStack(spacing: 4) {
                        Text(ref)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .underline()
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("Open referenced document")
                .disabled(referenceNavigator == nil)
            case .timestamp(let iso):
                let relative = value.relativeTimestamp ?? iso
                Text(relative)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .help(iso)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Text(value.preview)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Theme.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Theme.divider, lineWidth: 1)
        )
    }

    private func typeChip(for value: FirestoreValue) -> some View {
        let colors = Theme.chipColors(for: value.typeLabel)
        return Text(value.typeLabel)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(colors.fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(colors.bg)
            .cornerRadius(3)
    }

    @ViewBuilder
    private var children: some View {
        switch value {
        case .map(let entries):
            ForEach(Array(entries.enumerated()), id: \.offset) { item in
                FieldRow(name: item.element.name, value: item.element.value, depth: depth + 1)
            }
        case .array(let items):
            ForEach(Array(items.enumerated()), id: \.offset) { item in
                FieldRow(name: "[\(item.offset)]", value: item.element, depth: depth + 1)
            }
        default:
            EmptyView()
        }
    }
}
