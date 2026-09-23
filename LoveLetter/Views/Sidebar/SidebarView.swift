import SwiftUI

struct SidebarView: View {
    @Bindable var store: ProductStore
    let loaders: [UUID: IssueLoader]
    var seenStore: SeenIssueStore
    @Binding var selection: SidebarSelection?
    var onAddRepo: () -> Void = {}
    var onOpenProductSettings: (UUID) -> Void = { _ in }

    var body: some View {
        Group {
            if store.repos.isEmpty {
                ContentUnavailableView {
                    Label("No Products", systemImage: "tray")
                } description: {
                    Text("Add a product to start collecting feedback.")
                } actions: {
                    Button("Add Product") { onAddRepo() }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List(selection: $selection) {
                    ForEach(store.repos) { repo in
                        RepoSectionView(
                            repo: repo,
                            issues: issuesFor(repo),
                            selection: $selection,
                            store: store,
                            seenStore: seenStore,
                            onOpenSettings: onOpenProductSettings
                        )
                    }
                    .onMove { store.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.sidebar)
                #if os(macOS)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Button { onAddRepo() } label: {
                        Label("Add Product", systemImage: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                #else
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Button { onAddRepo() } label: {
                            Label("Add Product", systemImage: "plus.circle.fill")
                                .labelStyle(.titleAndIcon)
                        }
                    }
                }
                #endif
            }
        }
        .navigationTitle("Feedback")
        #if os(macOS)
        .frame(minWidth: 200)
        #endif
    }

    private func issuesFor(_ repo: ProductConfig) -> [FeedbackIssue] {
        guard let loader = loaders[repo.id],
              case .loaded(let issues, _) = loader.state else { return [] }
        return issues
    }
}
