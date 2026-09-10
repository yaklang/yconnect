import AppKit
import CoreServices

/// Explicit launches need a visible entry point; login launches stay in the menu bar.
enum StartupPresentation {
    enum Surface: Equatable { case background, widget, manager }

    static func isLoginItem(event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func surface(arguments: [String], loginItem: Bool) -> Surface {
        if arguments.contains("--show-manager") { return .manager }
        if arguments.contains("--show-widget") { return .widget }
        return loginItem ? .background : .widget
    }

    static let widgetSmokeArguments: Set<String> = [
        "--smoke-edge-widget-focus", "--smoke-widget-focus", "--smoke-widget-transient"
    ]
    static var allSmokeArguments: Set<String> { smokeArguments.union(widgetSmokeArguments) }

    static let smokeArguments: Set<String> = [
        "--smoke-startup", "--smoke-login-startup", "--smoke-startup-no-tray", "--smoke-startup-degraded"
    ]
}
