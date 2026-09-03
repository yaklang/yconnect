import Foundation
import XCTest
@testable import YConnect

final class LaunchAtLoginTests: XCTestCase {
    @MainActor
    func testEnablesLaunchAtLoginByDefaultForPackagedApplication() {
        let backend = MockLaunchAtLoginBackend(status: .disabled)
        let defaults = makeDefaults()
        let manager = LaunchAtLoginManager(
            backend: backend,
            defaults: defaults,
            packagedApplication: true
        )

        manager.enableByDefaultIfNeeded()

        XCTAssertEqual(backend.registerCallCount, 1)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginManager.firstLaunchKey))
    }

    @MainActor
    func testKeepsExplicitlyDisabledPreferenceOnLaterLaunches() {
        let backend = MockLaunchAtLoginBackend(status: .enabled)
        let defaults = makeDefaults()
        let manager = LaunchAtLoginManager(
            backend: backend,
            defaults: defaults,
            packagedApplication: true
        )

        XCTAssertTrue(manager.setEnabled(false))
        manager.enableByDefaultIfNeeded()

        XCTAssertEqual(backend.unregisterCallCount, 1)
        XCTAssertEqual(backend.registerCallCount, 0)
        XCTAssertFalse(manager.isEnabled)
    }

    @MainActor
    func testRetriesDefaultRegistrationAfterTransientFailure() {
        let backend = MockLaunchAtLoginBackend(status: .disabled)
        backend.registerError = TestError.registrationFailed
        let defaults = makeDefaults()
        let manager = LaunchAtLoginManager(
            backend: backend,
            defaults: defaults,
            packagedApplication: true
        )

        manager.enableByDefaultIfNeeded()
        XCTAssertFalse(defaults.bool(forKey: LaunchAtLoginManager.firstLaunchKey))

        backend.registerError = nil
        manager.enableByDefaultIfNeeded()

        XCTAssertEqual(backend.registerCallCount, 2)
        XCTAssertTrue(manager.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: LaunchAtLoginManager.firstLaunchKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "LaunchAtLoginTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

private enum TestError: Error {
    case registrationFailed
}

private final class MockLaunchAtLoginBackend: LaunchAtLoginBackend {
    var status: LaunchAtLoginStatus
    var registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .disabled
    }

    func openSystemSettings() {}
}
