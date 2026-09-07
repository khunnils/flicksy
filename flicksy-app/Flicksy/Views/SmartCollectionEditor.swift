import SwiftUI

struct SmartCollectionEditor: View {
    @Environment(BrowserModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let collection: SmartCollection?
    @State private var name: String
    @State private var definition: SmartCollectionDefinition
    @State private var template: SmartCollectionTemplate = .custom
    @State private var count: Int?
    @State private var previewError: String?
    @State private var saveError: String?
    @State private var saving = false

    init(collection: SmartCollection?) {
        self.collection = collection
        _name = State(initialValue: collection?.name ?? "")
        // Unreadable/future definitions remain visible in the sidebar until the
        // user explicitly saves replacement rules here.
        _definition = State(initialValue: collection?.definition.version == 1 ? collection!.definition : SmartCollectionDefinition())
    }

    private struct PreviewInput: Equatable {
        var definition: SmartCollectionDefinition
        var roots: [String]
        var tags: [LibraryTag]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(collection == nil ? "New Smart Collection" : "Edit Smart Collection").font(.headline)
            if collection == nil {
                Picker("Template", selection: $template) {
                    ForEach(SmartCollectionTemplate.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .onChange(of: template) { _, value in
                    definition = value.definition
                    name = value == .custom ? "" : value.rawValue
                }
            }
            TextField("Name", text: $name)
                .accessibilityLabel("Smart collection name")
            Picker("Search", selection: Binding(
                get: { definition.rootPath ?? "" },
                set: { definition.rootPath = $0.isEmpty ? nil : $0 }
            )) {
                Text("All added folders").tag("")
                ForEach(model.smartCollectionRoots, id: \.path) { root in
                    Text(root.path).tag(root.path)
                }
                if let path = definition.rootPath, !model.smartCollectionRoots.contains(where: { $0.path == path }) {
                    Text("Missing folder: \(path)").tag(path)
                }
            }
            HStack {
                Text("Match")
                Picker("Match", selection: $definition.match) {
                    Text("all").tag(SmartCollectionDefinition.Match.all)
                    Text("any").tag(SmartCollectionDefinition.Match.any)
                }
                .labelsHidden().frame(width: 85)
                Text("of the following rules:")
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach($definition.rules) { $rule in
                        SmartRuleRow(rule: $rule, tags: model.tags) {
                            definition.rules.removeAll { $0.id == rule.id }
                        }
                    }
                    Button("Add Rule", systemImage: "plus") { definition.rules.append(SmartCollectionRule()) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(2)
            }
            .frame(minHeight: 120, idealHeight: 180, maxHeight: 280)
            if let error = saveError ?? previewError {
                Text(error).font(.callout).foregroundStyle(.red)
            } else if let count {
                Text("\(count) matching \(count == 1 ? "file" : "files")").foregroundStyle(.secondary)
            } else {
                Text("Checking matches…").foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button(saving ? "Saving…" : "Save") {
                    saving = true
                    saveError = nil
                    Task {
                        do {
                            try await model.saveSmartCollection(id: collection?.id, name: name, definition: definition)
                            dismiss()
                        } catch {
                            saveError = error.localizedDescription
                            saving = false
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !definition.isValid || previewError != nil || count == nil)
            }
        }
        .padding(20)
        .frame(width: 720)
        .interactiveDismissDisabled(saving)
        .task(id: PreviewInput(definition: definition, roots: model.smartCollectionRoots.map(\.path), tags: model.tags)) {
            count = nil
            previewError = nil
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await model.previewSmartCollection(definition)
                try Task.checkCancellation()
                count = result
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                previewError = error.localizedDescription
            }
        }
    }
}

private struct SmartRuleRow: View {
    @Binding var rule: SmartCollectionRule
    let tags: [LibraryTag]
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Field", selection: $rule.field) {
                ForEach(SmartCollectionRule.Field.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 125)
            .onChange(of: rule.field) { _, field in
                rule.condition = field.conditions[0]
                if field == .modifiedDate { rule.number = 7 }
                if field == .tag { rule.tagID = tags.first?.id }
            }
            Picker("Condition", selection: $rule.condition) {
                ForEach(rule.field.conditions, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 160)
            valueEditor.frame(maxWidth: .infinity)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).accessibilityLabel("Remove rule")
        }
    }

    @ViewBuilder private var valueEditor: some View {
        switch rule.field {
        case .filename:
            TextField("Text", text: $rule.text)
        case .mediaType:
            Picker("Media type", selection: $rule.kind) {
                ForEach(SmartCollectionRule.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.labelsHidden()
        case .fileSize, .modifiedDate:
            HStack {
                TextField("Amount", value: $rule.number, format: .number)
                    .accessibilityLabel(rule.field == .fileSize ? "File size" : "Number of days")
                if rule.field == .fileSize {
                    Picker("Unit", selection: $rule.unit) {
                        ForEach(SmartCollectionRule.Unit.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 70)
                } else {
                    Text(rule.condition == .olderThanDays ? "days ago" : "days")
                }
            }
        case .tag:
            if rule.condition != .hasNoTags {
                Picker("Tag", selection: $rule.tagID) {
                    Text("Choose tag").tag(Optional<UUID>.none)
                    ForEach(tags) { Text($0.name).tag(Optional($0.id)) }
                    if let id = rule.tagID, !tags.contains(where: { $0.id == id }) {
                        Text("Missing tag").tag(Optional(id))
                    }
                }.labelsHidden()
            } else { Spacer() }
        case .favorite:
            Text("favorite").frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
