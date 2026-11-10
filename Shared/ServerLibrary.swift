import Foundation

/// Stores saved server profiles and the selected identity without including authentication secrets.
public struct ServerLibrary: Codable, Equatable, Sendable {
    public private(set) var profiles: [Profile]
    public private(set) var selectedID: UUID?
    public var selected: Profile? { profiles.first { $0.id == selectedID } }

    public init() { profiles = []; selectedID = nil }

    public init(profiles: [Profile], selectedID: UUID? = nil) throws {
        guard Set(profiles.map(\.id)).count == profiles.count,
              selectedID == nil || profiles.contains(where: { $0.id == selectedID }),
              profiles.isEmpty == (selectedID == nil) else {
            throw ConfigurationError.invalid("服务器列表或当前选择无效。")
        }
        self.profiles = profiles
        self.selectedID = selectedID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(profiles: values.decode([Profile].self, forKey: .profiles),
                      selectedID: values.decodeIfPresent(UUID.self, forKey: .selectedID))
    }

    public mutating func upsert(_ profile: Profile) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile }
        else { profiles.append(profile) }
        selectedID = profile.id
    }

    public mutating func select(_ id: UUID) throws {
        guard profiles.contains(where: { $0.id == id }) else { throw ConfigurationError.invalid("服务器已不存在。") }
        selectedID = id
    }

    public mutating func remove(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if selectedID == id { selectedID = profiles.first?.id }
    }
}
