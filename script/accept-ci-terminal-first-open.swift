// Acknowledge the ordinary first-open dialog only for verified test applications
// in GitHub's disposable macOS account. Never change Gatekeeper or TCC settings.
import AppKit
import ApplicationServices
import Foundation

func fail(_ message: String) -> Never {
    fputs("First-open acceptance failed: \(message)\n", stderr)
    exit(1)
}
guard ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == "true",
      CommandLine.arguments.count == 2 else { fail("requires a disposable GitHub Actions account and app path") }
let app = URL(fileURLWithPath: CommandLine.arguments[1])
guard app.deletingLastPathComponent().path == "/Applications",
      ["iTerm.app", "Ghostty.app", "kitty.app", "WezTerm.app"].contains(app.lastPathComponent),
      let bundleID = Bundle(url: app)?.bundleIdentifier else { fail("unexpected application") }
for (executable, arguments) in [
    ("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]),
    ("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", app.path])
] {
    let check = Process()
    check.executableURL = URL(fileURLWithPath: executable)
    check.arguments = arguments
    try check.run()
    check.waitUntilExit()
    guard check.terminationStatus == 0 else { fail("signature or Gatekeeper assessment rejected \(app.lastPathComponent)") }
}
let launch = Process()
launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
launch.arguments = ["-a", app.path]
try launch.run()

func attribute(_ element: AXUIElement, _ name: CFString) -> AnyObject? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else { return nil }
    return value
}
func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 12 else { return [element] }
    let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}
let deadline = Date().addingTimeInterval(30)
var accepted = false
while Date() < deadline {
    for agent in NSWorkspace.shared.runningApplications where agent.localizedName == "CoreServicesUIAgent" {
        let accessibility = AXUIElementCreateApplication(agent.processIdentifier)
        let windows = attribute(accessibility, kAXWindowsAttribute as CFString) as? [AXUIElement] ?? []
        for window in windows {
            let elements = descendants(window)
            let text = elements.flatMap { element in
                [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute].compactMap { attribute(element, $0 as CFString) as? String }
            }.joined(separator: " ")
            guard text.contains(app.deletingPathExtension().lastPathComponent),
                  text.contains("downloaded from the Internet"),
                  text.contains("Apple checked it for malicious software and none was detected") else { continue }
            guard let button = elements.first(where: {
                attribute($0, kAXRoleAttribute as CFString) as? String == kAXButtonRole &&
                attribute($0, kAXTitleAttribute as CFString) as? String == "Open"
            }), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { fail("cannot acknowledge verified first-open dialog") }
            accepted = true
        }
    }
    if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains(where: { $0.isFinishedLaunching }) {
        print("PASS: \(app.lastPathComponent), valid signature, Gatekeeper accepted, first launch completed (dialog acknowledged: \(accepted))")
        exit(0)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
fail("first launch timed out; accessibility trusted=\(AXIsProcessTrusted())")
