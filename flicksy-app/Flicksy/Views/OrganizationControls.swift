//
//  OrganizationControls.swift
//  Flicksy
//

import SwiftUI

struct OrganizationControl: View {
    @Environment(BrowserModel.self) private var model
    @State private var appliedTagIDs: Set<UUID> = []
    @State private var allFavorite = false

    var body: some View {
        @Bindable var model = model
        Button { model.isOrganizePresented.toggle() } label: { Label("Organize", systemImage: "tag") }
            .help("Organize selected media")
            .disabled(!model.canOrganizeSelection || model.viewerItemID != nil)
            .popover(isPresented: $model.isOrganizePresented) { popover }
    }

    private var popover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                model.toggleFavorite()
                allFavorite.toggle()
            } label: {
                Label(
                    allFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: allFavorite ? "star.slash" : "star"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Divider()
            Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if model.tags.isEmpty {
                Text("No tags yet").foregroundStyle(.tertiary)
            } else {
                ForEach(model.tags) { tag in
                    Toggle(isOn: Binding(
                        get: { appliedTagIDs.contains(tag.id) },
                        set: { enabled in
                            if enabled { appliedTagIDs.insert(tag.id) } else { appliedTagIDs.remove(tag.id) }
                            model.setTag(tag, enabled: enabled)
                        }
                    )) {
                        HStack {
                            Circle().fill(tag.color.color).frame(width: 8, height: 8)
                            Text(tag.name)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            Button("New Tag…") { model.organizationEditorRequest = .newTag(applyingSelection: true) }

            Divider()
            Text("Add to Collection").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(model.collections) { collection in
                Button(collection.name) { model.addToCollection(collection) }.buttonStyle(.plain)
            }
            Button("New Collection…") { model.organizationEditorRequest = .newCollection(addingSelection: true) }
        }
        .padding(14)
        .frame(minWidth: 240, alignment: .leading)
        .task {
            appliedTagIDs = await model.tagsAppliedToEverySelectedItem()
            allFavorite = model.selectionIsAllFavorite()
        }
    }
}
