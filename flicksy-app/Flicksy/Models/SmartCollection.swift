import Foundation

nonisolated struct SmartCollection: Identifiable, Hashable, Sendable {
    var id: UUID = UUID()
    var name: String
    var definition: SmartCollectionDefinition
    var itemCount: Int = 0
    var repairMessage: String?
}

nonisolated struct SmartCollectionDefinition: Codable, Hashable, Sendable {
    var version = 1
    var rootPath: String?
    var match: Match = .all
    var rules: [SmartCollectionRule] = [SmartCollectionRule()]

    enum Match: String, Codable, CaseIterable { case all, any }
    var usesRelativeDates: Bool { rules.contains { $0.field == .modifiedDate } }
    var isValid: Bool { version == 1 && !rules.isEmpty && rules.allSatisfy(\.isValid) }

    func summary(tags: [LibraryTag]) -> String {
        let scope = rootPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All added folders"
        return scope + " · " + rules.map { $0.summary(tags: tags) }.joined(separator: match == .all ? " AND " : " OR ")
    }
}

nonisolated struct SmartCollectionRule: Identifiable, Codable, Hashable, Sendable {
    enum Field: String, Codable, CaseIterable {
        case filename = "Filename", mediaType = "Media type", fileSize = "File size"
        case modifiedDate = "Modified date", tag = "Tag", favorite = "Favorite"
        var conditions: [Condition] {
            switch self {
            case .filename: [.contains, .doesNotContain]
            case .mediaType, .favorite: [.isValue, .isNot]
            case .fileSize: [.greaterThan, .lessThan]
            case .modifiedDate: [.withinDays, .olderThanDays]
            case .tag: [.hasTag, .doesNotHaveTag, .hasNoTags]
            }
        }
    }
    enum Condition: String, Codable, CaseIterable {
        case contains = "contains", doesNotContain = "does not contain"
        case isValue = "is", isNot = "is not"
        case greaterThan = "greater than", lessThan = "less than"
        case withinDays = "within the last", olderThanDays = "more than"
        case hasTag = "has", doesNotHaveTag = "does not have", hasNoTags = "has no tags"
    }
    enum Kind: String, Codable, CaseIterable { case image = "Image", video = "Video", audio = "Audio" }
    enum Unit: String, Codable, CaseIterable {
        case mb = "MB", gb = "GB"
        var multiplier: Double { self == .mb ? 1_000_000 : 1_000_000_000 }
    }
    var id = UUID()
    var field: Field = .filename
    var condition: Condition = .contains
    var text = ""
    var number: Double = 100
    var unit: Unit = .mb
    var kind: Kind = .image
    var tagID: UUID?
    var isValid: Bool {
        guard field.conditions.contains(condition) else { return false }
        switch field {
        case .filename: return !text.isEmpty
        case .fileSize: return number.isFinite && number >= 0 && number * unit.multiplier < Double(Int64.max)
        case .modifiedDate: return number.isFinite && number > 0 && number <= 365_000 && number.rounded() == number
        case .tag: return condition == .hasNoTags || tagID != nil
        case .mediaType, .favorite: return true
        }
    }
    func summary(tags: [LibraryTag]) -> String {
        let value: String
        switch field {
        case .filename: value = "“\(text)”"
        case .mediaType: value = kind.rawValue
        case .fileSize: value = "\(number.formatted()) \(unit.rawValue)"
        case .modifiedDate: value = "\(number.formatted()) days" + (condition == .olderThanDays ? " ago" : "")
        case .tag: value = condition == .hasNoTags ? "" : (tags.first { $0.id == tagID }?.name ?? "Missing tag")
        case .favorite: value = "true"
        }
        return "\(field.rawValue) \(condition.rawValue) \(value)".trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum SmartCollectionTemplate: String, CaseIterable {
    case custom = "Start from Scratch", large = "Large Files", recent = "Recently Modified", untagged = "Untagged"
    var definition: SmartCollectionDefinition {
        var rule = SmartCollectionRule()
        switch self {
        case .custom: break
        case .large: rule.field = .fileSize; rule.condition = .greaterThan
        case .recent: rule.field = .modifiedDate; rule.condition = .withinDays; rule.number = 7
        case .untagged: rule.field = .tag; rule.condition = .hasNoTags
        }
        return SmartCollectionDefinition(rules: [rule])
    }
}

nonisolated enum SmartCollectionError: LocalizedError {
    case invalidRules, missingRoot, missingTag, unsupportedDefinition
    var errorDescription: String? {
        switch self {
        case .invalidRules: "Add at least one valid rule and complete every rule."
        case .missingRoot: "The scoped folder was removed. Edit Rules to choose an added folder."
        case .missingTag: "A referenced tag was removed. Edit Rules to choose another tag."
        case .unsupportedDefinition: "These saved rules could not be read. Edit Rules to replace them."
        }
    }
}
