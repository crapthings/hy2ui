import Foundation
import Observation

/// Initializes editable data after recovery resources are available to the application.
@MainActor @Observable
public final class ApplicationSession {
    public let editor: ProfileEditor
    public let connection: ConnectionCoordinator
    public private(set) var initialized = false
    private var initializing = false

    public init(editor: ProfileEditor, connection: ConnectionCoordinator) {
        self.editor = editor
        self.connection = connection
    }

    public func initialize() async {
        guard !initialized, !initializing else { return }
        initializing = true
        connection.refreshRecovery()
        editor.initialize()
        await connection.loadExistingVPN()
        initialized = true
        initializing = false
    }
}
