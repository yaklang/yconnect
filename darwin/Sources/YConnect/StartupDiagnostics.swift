import Foundation
import Darwin

/// A small, local journal of lifecycle checkpoints. Never accepts credentials,
/// URLs, command lines, server responses, or arbitrary exception text.
@MainActor
final class StartupDiagnostics {
    enum Stage: String, Codable {
        case starting, controllerReady, menuBarReady, loginItemChecked
        case widgetVisible, managerVisible, clientRegistryUnavailable, loginItemUnavailable, keychainUnavailable, cleanExit
    }
    struct Report: Codable {
        var processID: Int32
        var startedAt: Date
        var updatedAt: Date
        var version: String
        var build: String
        var system: String
        var architecture: String
        var stage: Stage
        var keychainStatus: Int32?
        var issues: [Stage]
        var finished: Bool
        var acknowledged: Bool
    }

    let directory: URL
    private(set) var previousInterruptedStage: Stage?
    private(set) var storageWarning: String?
    private let reportURL: URL
    private var report: Report

    static func directory(for environment: AppEnvironment) -> URL {
        environment.applicationSupportDirectory.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    init(directory: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier,
         isProcessRunning: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }) {
        self.directory = directory
        reportURL = directory.appendingPathComponent("startup-\(UUID().uuidString).json")
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        report = Report(processID: processID, startedAt: Date(), updatedAt: Date(),
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? BuildInfo.version,
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development",
            system: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            stage: .starting, issues: [], finished: false, acknowledged: false)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let files = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let reports: [(URL, Report)] = files.compactMap { url in
                guard url.lastPathComponent.hasPrefix("startup-"), url.pathExtension == "json",
                      let attributes = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                      attributes.isRegularFile == true, attributes.isSymbolicLink != true,
                      (attributes.fileSize ?? Int.max) < 65_536,
                      let data = try? Data(contentsOf: url), let previous = try? JSONDecoder().decode(Report.self, from: data)
                else { return nil }
                return (url, previous)
            }.sorted { $0.1.updatedAt > $1.1.updatedAt }
            for (index, entry) in reports.enumerated() {
                var previous = entry.1
                guard !isProcessRunning(previous.processID) else { continue }
                if !previous.finished && !previous.acknowledged {
                    if previousInterruptedStage == nil { previousInterruptedStage = previous.stage }
                    previous.acknowledged = true
                    try write(previous, to: entry.0)
                }
                if index >= 9 { try? FileManager.default.removeItem(at: entry.0) }
            }
            try write(report, to: reportURL)
        } catch {
            storageWarning = "无法保存启动诊断，请检查应用数据目录是否可写。应用仍可继续使用。"
        }
    }

    func recordKeychainFailure(status: Int32) {
        report.keychainStatus = status
        record(.keychainUnavailable)
    }

    func record(_ stage: Stage) {
        report.stage = stage
        if [.clientRegistryUnavailable, .loginItemUnavailable, .keychainUnavailable].contains(stage), !report.issues.contains(stage) {
            report.issues.append(stage)
        }
        report.updatedAt = Date()
        report.finished = stage == .cleanExit
        do { try write(report, to: reportURL) }
        catch { storageWarning = "无法保存启动诊断，请检查应用数据目录是否可写。应用仍可继续使用。" }
    }

    private func write(_ report: Report, to url: URL) throws {
        let data = try JSONEncoder().encode(report)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
