import SwiftData
import SwiftUI

struct RootView: View {
    let storageError: String?
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.home
    @State private var openedDocumentID: UUID?
    @State private var importError: String?

    enum Tab: Hashable { case home, documents, search, settings }

    var body: some View {
        @Bindable var settings = services.settings
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            DocumentListView()
                .tabItem { Label("Documents", systemImage: "doc.text") }
                .tag(Tab.documents)
            SearchView()
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay {
            if services.lock.isLocked { LockView() }
        }
        .fullScreenCover(isPresented: .constant(!settings.hasCompletedOnboarding)) {
            OnboardingView()
        }
        .sheet(item: Binding(get: { openedDocumentID.map(IdentifiedID.init) }, set: { openedDocumentID = $0?.id })) { item in
            NavigationStack { DocumentDetailLoader(documentID: item.id) }
        }
        .onChange(of: services.notifications.openDocumentRequest) { _, id in
            if let id {
                openedDocumentID = id
                services.notifications.openDocumentRequest = nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: services.becameActive(context: context)
            case .background: services.lock.lock(ifEnabled: services.settings.appLockEnabled)
            default: break
            }
        }
        .onOpenURL { url in
            do {
                let doc = try services.importer.importFile(at: url, origin: .share, context: context)
                services.process(doc, context: context)
                openedDocumentID = doc.id
            } catch {
                importError = error.localizedDescription
            }
        }
        .task {
            services.lock.lock(ifEnabled: services.settings.appLockEnabled)
            if services.lock.isLocked { await services.lock.unlock() }
        }
        .alert("Couldn’t import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .alert("Storage problem", isPresented: .constant(storageError != nil && !dismissedStorageError)) {
            Button("OK") { dismissedStorageError = true }
        } message: { Text(storageError ?? "") }
    }

    @State private var dismissedStorageError = false
}

struct IdentifiedID: Identifiable, Hashable {
    let id: UUID
}

/// Fetches a document by id (used for deep links and search results).
struct DocumentDetailLoader: View {
    let documentID: UUID
    @Query private var docs: [DocumentRecord]
    @Environment(\.dismiss) private var dismiss

    init(documentID: UUID) {
        self.documentID = documentID
        _docs = Query(filter: #Predicate<DocumentRecord> { $0.id == documentID })
    }

    var body: some View {
        if let doc = docs.first {
            DocumentDetailView(document: doc)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        } else {
            ContentUnavailableView("Document not found", systemImage: "doc.questionmark", description: Text("It may have been deleted."))
        }
    }
}

struct LockView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        ZStack {
            Rectangle().fill(.background).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Doxi is locked").font(.headline)
                Button("Unlock with \(AppLock.biometryName)") {
                    Task { await services.lock.unlock() }
                }
                .buttonStyle(.borderedProminent)
                if let error = services.lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
                }
            }
        }
        .accessibilityAddTraits(.isModal)
    }
}
