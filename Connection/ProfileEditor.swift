import Foundation
import Observation
#if SWIFT_PACKAGE
import Hy2Models
#endif

/// Manages selected server drafts and persistence while keeping secrets and storage errors separate.
@MainActor @Observable
public final class ProfileEditor {
    public var profile = Profile()
    public var credentials = Credentials()
    public private(set) var notice: String?
    public private(set) var noticeIsError = false
    public private(set) var library = ServerLibrary()
    public private(set) var isNewServer = false
    private let repository: any ProfilePersisting
    private var loaded = false
    private var savedProfile: Profile?
    private var savedCredentials = Credentials()
    private var credentialsLoaded = false

    public var profiles: [Profile] {
        var result = library.profiles
        if let index = result.firstIndex(where: { $0.id == profile.id }) { result[index] = profile }
        else if isNewServer { result.append(profile) }
        return result
    }
    public var hasServer: Bool { isNewServer || library.selected != nil }
    public var hasChanges: Bool { isNewServer || (savedProfile != nil && (profile != savedProfile || credentials != savedCredentials)) }

    public init(repository: any ProfilePersisting) { self.repository = repository }

    public func initialize() {
        guard !loaded else { return }
        loaded = true
        do {
            library = try repository.load()
            if let selected = library.selected {
                profile = selected
                savedProfile = selected
                credentials = try repository.credentials(for: selected)
                savedCredentials = credentials
                credentialsLoaded = true
            }
        } catch { report(error) }
    }

    public func select(_ id: UUID) throws {
        guard profile.id != id else { return }
        if hasChanges { try save() }
        guard let next = library.profiles.first(where: { $0.id == id }) else {
            throw ConfigurationError.invalid("服务器已不存在。")
        }
        let secrets = try repository.credentials(for: next)
        try repository.select(id)
        try library.select(id)
        profile = next
        credentials = secrets
        savedProfile = next
        savedCredentials = secrets
        credentialsLoaded = true
        isNewServer = false
        clearNotice()
    }

    public func add() throws {
        if hasChanges { try save() }
        let previous = profile
        profile = Profile()
        profile.name = "新服务器"
        profile.systemProxyEnabled = previous.systemProxyEnabled
        profile.enhancedModeEnabled = previous.enhancedModeEnabled
        profile.enhancedBackend = previous.enhancedBackend
        profile.httpPort = previous.httpPort
        profile.socksPort = previous.socksPort
        profile.mtu = previous.mtu
        profile.dns = previous.dns
        credentials = Credentials()
        credentialsLoaded = false
        isNewServer = true
        clearNotice()
    }

    public func credentialsForMeasurement(_ id: UUID) throws -> Credentials {
        if profile.id == id { return credentials }
        guard let saved = library.profiles.first(where: { $0.id == id }) else {
            throw ConfigurationError.invalid("服务器已不存在。")
        }
        return try repository.credentials(for: saved)
    }

    public func remove(_ id: UUID) throws {
        if id == profile.id { try removeCurrent(); return }
        guard library.profiles.contains(where: { $0.id == id }) else { return }
        try repository.remove(id)
        library = try repository.load()
    }

    public func removeCurrent() throws {
        let removed = profile.id
        if !isNewServer { try repository.remove(removed) }
        library = try repository.load()
        profile = library.selected ?? Profile()
        savedProfile = library.selected
        credentials = Credentials()
        credentialsLoaded = false
        savedCredentials = Credentials()
        isNewServer = false
        if library.selected != nil {
            credentials = try repository.credentials(for: profile)
            savedCredentials = credentials
            credentialsLoaded = true
        }
        noticeIsError = false
        notice = "已删除"
    }

    public func save() throws {
        do {
            try profile.validate()
            if !isNewServer, credentialsLoaded, savedProfile == profile, savedCredentials == credentials {
                noticeIsError = false
                notice = "已保存"
                return
            }
            try repository.save(profile, credentials: credentials)
            library.upsert(profile)
            savedProfile = profile
            savedCredentials = credentials
            credentialsLoaded = true
            isNewServer = false
            noticeIsError = false
            notice = "已保存"
        } catch {
            report(error)
            throw error
        }
    }

    public func clearNotice() { notice = nil; noticeIsError = false }
    public func report(_ error: Error) { notice = error.localizedDescription; noticeIsError = true }
}
