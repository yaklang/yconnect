import XCTest
@testable import YConnect

final class AppUpdateTests: XCTestCase {
    private func fixture(version: String = "0.10.0", mutate: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        let name = "YConnect-\(version)-darwin-universal.dmg"
        var value: [String: Any] = ["schema_version": 1, "product": "yconnect", "version": version,
            "release_notes": "https://github.com/yaklang/yconnect/releases/tag/v\(version)",
            "assets": [["platform": "darwin", "architecture": "universal", "kind": "dmg", "filename": name,
                "url": "\(AppRelease.base)/\(version)/\(name)", "sha256": String(repeating: "a", count: 64), "size": 100]]]
        mutate(&value)
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testNumericVersionsAndNoDowngrade() throws {
        XCTAssertNotNil(try AppRelease.parse(fixture(), currentVersion: "0.9.9"))
        XCTAssertNil(try AppRelease.parse(fixture(), currentVersion: "0.10.0"))
        XCTAssertNil(try AppRelease.parse(fixture(), currentVersion: "1.0.0"))
        for version in ["1.2", "01.2.3", "1.2.3-beta", "-1.2.3", "1.2.3.4", "９.0.0"] { XCTAssertNil(ReleaseVersion(version)) }
    }
    func testRejectsWrongProductAndLinksAndDuplicateAssets() throws {
        for field in ["product", "release_notes"] {
            XCTAssertThrowsError(try AppRelease.parse(fixture { $0[field] = "https://untrusted.invalid" }, currentVersion: "0.5.0"))
        }
        for field in ["url", "filename", "sha256", "architecture"] {
            let data = try fixture { value in
                var assets = value["assets"] as! [[String: Any]]; assets[0][field] = "invalid"; value["assets"] = assets
            }
            XCTAssertThrowsError(try AppRelease.parse(data, currentVersion: "0.5.0"))
        }
        XCTAssertThrowsError(try AppRelease.parse(fixture { value in
            let assets = value["assets"] as! [[String: Any]]; value["assets"] = assets + assets
        }, currentVersion: "0.5.0"))
        XCTAssertThrowsError(try AppRelease.parse(Data(repeating: 32, count: 524_289), currentVersion: "0.5.0"))
    }
    @MainActor func testDevelopmentNeverChecksOrInstallsOrChangesProductionPreference() async throws {
        let suite = "yconnect-updater-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let updater = AppUpdates(enabled: false, defaults: defaults)
        updater.start(); await updater.check(); updater.install(); updater.automaticallyChecks = false
        XCTAssertFalse(updater.installing); XCTAssertFalse(updater.checking); XCTAssertNil(updater.release)
        XCTAssertNil(defaults.object(forKey: "YConnectCheckUpdates"))
    }
}
