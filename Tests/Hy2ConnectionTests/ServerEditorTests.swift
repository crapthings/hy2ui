import Foundation
import Testing
import Hy2Models
@testable import Hy2Connection

/// Persists test server identities and secrets in memory without accessing files or the Keychain.
@MainActor
private final class LibraryRepository: ProfilePersisting {
    var library = ServerLibrary()
    var secrets: [UUID: Credentials] = [:]
    var saveFails = false
    var credentialsFail = false
    var saves = 0
    func load() throws -> ServerLibrary { library }
    func save(_ profile: Profile, credentials: Credentials) throws {
        if saveFails { throw ConfigurationError.invalid("Save failed") }
        library.upsert(profile, selecting: false)
        secrets[profile.id] = credentials
        saves += 1
    }
    func select(_ id: UUID) throws { try library.select(id) }
    func remove(_ id: UUID) throws { library.remove(id); secrets.removeValue(forKey: id) }
    func credentials(for profile: Profile) throws -> Credentials {
        if credentialsFail { throw ConfigurationError.invalid("Keychain unavailable") }
        return secrets[profile.id] ?? Credentials()
    }
}

/// Switches persisted server identity and credentials together while saving outstanding valid edits.
@Test @MainActor func serverSelectionKeepsCredentialsSeparate() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    try repository.select(second.id)
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    #expect(editor.profile.id == second.id)
    editor.profile.name = "Renamed"
    try editor.select(first.id)
    #expect(editor.credentials.password == "first")
    #expect(repository.library.profiles.last?.name == "Renamed")
    #expect(repository.secrets[second.id]?.password == "second")
    #expect(repository.library.selectedID == first.id)
}

/// Keeps the original draft and credentials when saving or reading the next server fails.
@Test @MainActor func failedServerSwitchPreservesCurrentDraft() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    try repository.select(second.id)
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    editor.profile.name = "Keep this edit"
    repository.saveFails = true
    #expect(throws: (any Error).self) { try editor.select(first.id) }
    #expect(editor.profile.id == second.id && editor.profile.name == "Keep this edit")
    #expect(editor.credentials.password == "second")
    repository.saveFails = false
    try editor.save()
    repository.credentialsFail = true
    #expect(throws: (any Error).self) { try editor.select(first.id) }
    #expect(editor.profile.id == second.id && repository.library.selectedID == second.id)
}

/// Adds independent server drafts without copying another server's authentication secrets.
@Test @MainActor func newServerDraftDoesNotCopySecrets() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"; first.enhancedModeEnabled = true
    try repository.save(first, credentials: Credentials(password: "first", obfuscationPassword: "obfs"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    try editor.add()
    #expect(editor.profile.id != first.id)
    #expect(editor.credentials == Credentials())
    #expect(editor.profile.enhancedModeEnabled)
    #expect(editor.profiles.count == 2 && editor.isNewServer)
    editor.profile.host = "new.example.com"
    editor.credentials.password = "new"
    try editor.save()
    #expect(repository.library.profiles.count == 2)
    #expect(repository.secrets[first.id]?.password == "first")
}

/// Removes a saved server and selects the next server with its own secret.
@Test @MainActor func serverRemovalLoadsRemainingIdentity() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    try repository.select(second.id)
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    try editor.removeCurrent()
    #expect(editor.profile.id == first.id && editor.credentials.password == "first")
    #expect(repository.secrets[second.id] == nil)
    try editor.removeCurrent()
    #expect(!editor.hasServer && editor.profiles.isEmpty && editor.credentials == Credentials())
}

/// Discards an unsaved server without deleting an existing server or its Keychain identity.
@Test @MainActor func unsavedServerCanBeRemovedWithoutPersisting() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    try editor.add()
    try editor.removeCurrent()
    #expect(editor.profile == first && editor.credentials.password == "first")
    #expect(repository.saves == 1)
}

/// Avoids touching persistent credentials again when connecting with an unchanged saved server.
@Test @MainActor func unchangedServerSaveDoesNotRewriteCredentials() throws {
    let repository = LibraryRepository()
    var profile = Profile()
    profile.host = "example.com"
    try repository.save(profile, credentials: Credentials(password: "saved-secret"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    repository.saveFails = true
    try editor.save()
    try editor.save()
    #expect(repository.saves == 1)
    editor.credentials.password = "changed-secret"
    #expect(throws: (any Error).self) { try editor.save() }
    #expect(editor.hasChanges)
}

/// Keeps actionable save errors distinguishable from the brief success notice used by the interface.
@Test @MainActor func saveFeedbackDoesNotHideFailures() throws {
    let repository = LibraryRepository()
    var profile = Profile()
    profile.host = "example.com"
    try repository.save(profile, credentials: Credentials(password: "secret"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    editor.profile.name = "Edited"
    repository.saveFails = true
    #expect(throws: (any Error).self) { try editor.save() }
    #expect(editor.noticeIsError && editor.notice != nil)
    repository.saveFails = false
    try editor.save()
    #expect(!editor.noticeIsError && editor.notice == "已保存")
    editor.clearNotice()
    #expect(editor.notice == nil && !editor.noticeIsError)
}

/// Deletes an unselected server without loading credentials or discarding the selected draft.
@Test @MainActor func deletingUnselectedServerPreservesDraft() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    try repository.select(second.id)
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    editor.profile.name = "Unsaved draft"
    repository.credentialsFail = true
    try editor.remove(first.id)
    #expect(editor.profile.id == second.id)
    #expect(editor.profile.name == "Unsaved draft")
    #expect(editor.hasChanges)
    #expect(editor.library.profiles.map(\.id) == [second.id])
    #expect(repository.secrets[first.id] == nil)
    #expect(editor.credentials.password == "second")
}

/// Reads another server's measurement credentials without selecting it or saving the active draft.
@Test @MainActor func latencyCredentialReadPreservesSelectedDraft() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    try repository.select(second.id)
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    editor.profile.host = ""
    let saves = repository.saves
    let secrets = try editor.credentialsForMeasurement(first.id)
    #expect(secrets.password == "first")
    #expect(editor.profile.id == second.id && editor.profile.host.isEmpty)
    #expect(repository.library.selectedID == second.id && repository.saves == saves)
}

/// Keeps the default proxy stable while another server is opened, renamed and saved.
@Test @MainActor func editingServerDoesNotChangeDefaultPolicy() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    var second = Profile(); second.host = "second.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    try repository.save(second, credentials: Credentials(password: "second"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    try editor.edit(second.id)
    #expect(editor.profile.id == second.id && editor.credentials.password == "second")
    #expect(editor.library.selectedID == first.id && repository.library.selectedID == first.id)
    editor.profile.name = "Renamed second"
    try editor.save()
    #expect(editor.library.selectedID == first.id && repository.library.selectedID == first.id)
    try editor.select(second.id)
    #expect(editor.library.selectedID == second.id && repository.library.selectedID == second.id)
}

/// Adds new server credentials without replacing an already selected default proxy.
@Test @MainActor func addingServerPreservesDefaultPolicy() throws {
    let repository = LibraryRepository()
    var first = Profile(); first.host = "first.example.com"
    try repository.save(first, credentials: Credentials(password: "first"))
    let editor = ProfileEditor(repository: repository)
    editor.initialize()
    try editor.add()
    editor.profile.host = "new.example.com"
    try editor.save()
    #expect(editor.library.profiles.count == 2)
    #expect(editor.library.selectedID == first.id && repository.library.selectedID == first.id)
}
