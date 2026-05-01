import Foundation
import SwiftUI
import WidgetKit

struct LimitWindow {
    let name: String
    let usedPercent: Int?
    let resetDate: Date?

    var remainingPercent: Int? {
        guard let usedPercent else {
            return nil
        }
        return max(0, 100 - usedPercent)
    }
}

struct CodexLimits {
    let plan: String?
    let primary: LimitWindow?
    let secondary: LimitWindow?
    let updatedAt: Date
    let error: String?

    static let placeholder = CodexLimits(
        plan: "plus",
        primary: LimitWindow(
            name: "5h",
            usedPercent: 24,
            resetDate: Date().addingTimeInterval(3 * 60 * 60 + 25 * 60)
        ),
        secondary: LimitWindow(
            name: "weekly",
            usedPercent: 10,
            resetDate: Date().addingTimeInterval(6 * 24 * 60 * 60 + 8 * 60 * 60)
        ),
        updatedAt: Date(),
        error: nil
    )
}

struct CodexLimitsEntry: TimelineEntry {
    let date: Date
    let limits: CodexLimits
}

enum ResetDisplayStyle {
    case relative
    case absolute
}

struct CodexLimitsProvider: TimelineProvider {
    func placeholder(in context: Context) -> CodexLimitsEntry {
        CodexLimitsEntry(date: Date(), limits: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (CodexLimitsEntry) -> Void) {
        completion(CodexLimitsEntry(date: Date(), limits: CodexLimitsReader.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CodexLimitsEntry>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let now = Date()
            let entry = CodexLimitsEntry(date: now, limits: CodexLimitsReader.read())
            let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: now) ?? now.addingTimeInterval(300)
            completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
        }
    }
}

struct CodexLimitsReader {
    static func read() -> CodexLimits {
        do {
            let codexPath = try findCodex()
            let result = try callCodexAppServer(codexPath: codexPath)
            let bucket = pickCodexBucket(from: result)
            return parseLimits(from: bucket)
        } catch {
            return CodexLimits(
                plan: nil,
                primary: nil,
                secondary: nil,
                updatedAt: Date(),
                error: String(describing: error)
            )
        }
    }

    private static func findCodex() throws -> String {
        let envPath = ProcessInfo.processInfo.environment["CODEX_BIN"]
        let candidates = [
            envPath,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/usr/bin/codex"
        ].compactMap { $0 }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        throw WidgetError.codexNotFound
    }

    private static func callCodexAppServer(codexPath: String) throws -> [String: Any] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.environment = codexEnvironment()
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let reader = JSONLineReader(
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        defer {
            try? stdin.fileHandleForWriting.close()
            reader.stop()
            if process.isRunning {
                process.terminate()
            }
        }
        try writeJSON([
            "id": 1,
            "method": "initialize",
            "params": [
                "clientInfo": [
                    "name": "codex-limits-widget",
                    "version": "0.2.1"
                ],
                "capabilities": [
                    "experimentalApi": true
                ]
            ]
        ], to: stdin.fileHandleForWriting)
        _ = try reader.waitForMessage(id: 1, process: process, deadline: Date().addingTimeInterval(15))
        try writeJSON([
            "id": 2,
            "method": "account/rateLimits/read"
        ], to: stdin.fileHandleForWriting)
        var message = try reader.waitForMessage(id: 2, process: process, deadline: Date().addingTimeInterval(15))
        if let error = message["error"], isCodexAccountAuthRequired(error) {
            let auth = try readChatGPTAuthTokens()
            try writeJSON([
                "id": 3,
                "method": "account/login/start",
                "params": [
                    "type": "chatgptAuthTokens",
                    "accessToken": auth.accessToken,
                    "chatgptAccountId": auth.accountId,
                    "chatgptPlanType": auth.planType
                ]
            ], to: stdin.fileHandleForWriting)
            let loginMessage = try reader.waitForMessage(
                id: 3,
                process: process,
                deadline: Date().addingTimeInterval(15)
            )
            if let loginError = loginMessage["error"] {
                throw WidgetError.serverError(serverErrorDescription(loginError))
            }
            try writeJSON([
                "id": 4,
                "method": "account/rateLimits/read"
            ], to: stdin.fileHandleForWriting)
            message = try reader.waitForMessage(id: 4, process: process, deadline: Date().addingTimeInterval(15))
        }
        if let error = message["error"] {
            throw WidgetError.serverError(serverErrorDescription(error))
        }
        if let result = message["result"] as? [String: Any] {
            return result
        }
        throw WidgetError.missingRateLimits
    }

    private static func codexEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        environment["HOME"] = home
        environment["CODEX_HOME"] = "\(home)/.codex"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if environment["USER"] == nil {
            environment["USER"] = NSUserName()
        }
        if environment["LOGNAME"] == nil {
            environment["LOGNAME"] = NSUserName()
        }
        return environment
    }

    private static func isCodexAccountAuthRequired(_ error: Any) -> Bool {
        serverErrorDescription(error).localizedCaseInsensitiveContains(
            "codex account authentication required to read rate limits"
        )
    }

    private static func serverErrorDescription(_ error: Any) -> String {
        if
            let dict = error as? [String: Any],
            let message = dict["message"] as? String
        {
            return message
        }
        return String(describing: error)
    }

    private static func readChatGPTAuthTokens() throws -> ChatGPTAuthTokens {
        let authURL = authSnapshotURL()
        guard let data = try? Data(contentsOf: authURL) else {
            throw WidgetError.authUnavailable
        }
        guard
            let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = auth["accessToken"] as? String,
            let accountId = auth["accountId"] as? String,
            let planType = auth["planType"] as? String
        else {
            throw WidgetError.authUnavailable
        }
        return ChatGPTAuthTokens(
            accessToken: accessToken,
            accountId: accountId,
            planType: planType
        )
    }

    private static func authSnapshotURL() -> URL {
        let applicationSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return applicationSupportURL
            .appendingPathComponent("CodexLimits", isDirectory: true)
            .appendingPathComponent("external-auth.json")
    }

    private static func writeJSON(_ object: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        guard let string = String(data: data, encoding: .utf8) else {
            throw WidgetError.invalidOutput
        }
        handle.write(Data((string + "\n").utf8))
    }

    private static func pickCodexBucket(from result: [String: Any]) -> [String: Any] {
        if
            let buckets = result["rateLimitsByLimitId"] as? [String: Any],
            let codex = buckets["codex"] as? [String: Any]
        {
            return codex
        }
        return (result["rateLimits"] as? [String: Any]) ?? result
    }

    private static func parseLimits(from bucket: [String: Any]) -> CodexLimits {
        CodexLimits(
            plan: bucket["planType"] as? String,
            primary: parseWindow(bucket["primary"], fallbackName: "5h"),
            secondary: parseWindow(bucket["secondary"], fallbackName: "weekly"),
            updatedAt: Date(),
            error: nil
        )
    }

    private static func parseWindow(_ value: Any?, fallbackName: String) -> LimitWindow? {
        guard let dict = value as? [String: Any] else {
            return nil
        }
        let duration = number(dict["windowDurationMins"])
        let name: String
        switch duration {
        case 300:
            name = "5h"
        case 10080:
            name = "weekly"
        case let minutes? where minutes % 1440 == 0:
            name = "\(minutes / 1440)d"
        case let minutes? where minutes % 60 == 0:
            name = "\(minutes / 60)h"
        case let minutes?:
            name = "\(minutes)m"
        default:
            name = fallbackName
        }
        let resetDate = number(dict["resetsAt"]).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        return LimitWindow(
            name: name,
            usedPercent: number(dict["usedPercent"]),
            resetDate: resetDate
        )
    }

    static func number(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }
}

struct ChatGPTAuthTokens {
    let accessToken: String
    let accountId: String
    let planType: String
}

final class JSONLineReader {
    private let stdout: FileHandle
    private let stderr: FileHandle
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var stdoutBuffer = Data()
    private var messages: [[String: Any]] = []
    private var stderrText = ""

    init(stdout: FileHandle, stderr: FileHandle) {
        self.stdout = stdout
        self.stderr = stderr
        stdout.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.appendStdout(data)
        }
        stderr.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                return
            }
            self?.appendStderr(data)
        }
    }

    func stop() {
        stdout.readabilityHandler = nil
        stderr.readabilityHandler = nil
    }

    func waitForMessage(id: Int, process: Process, deadline: Date) throws -> [String: Any] {
        while Date() < deadline {
            if let message = takeMessage(id: id) {
                return message
            }
            if !process.isRunning {
                if let message = takeMessage(id: id) {
                    return message
                }
                throw WidgetError.missingRateLimits
            }
            let milliseconds = max(1, min(200, Int(deadline.timeIntervalSinceNow * 1000)))
            _ = signal.wait(timeout: .now() + .milliseconds(milliseconds))
        }
        if process.isRunning {
            process.terminate()
        }
        throw WidgetError.timeout
    }

    private func appendStdout(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        stdoutBuffer.append(data)
        let newline = Data([0x0A])
        while let range = stdoutBuffer.range(of: newline) {
            let lineData = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<range.upperBound)
            guard
                !lineData.isEmpty,
                let message = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else {
                continue
            }
            messages.append(message)
            signal.signal()
        }
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if let text = String(data: data, encoding: .utf8) {
            stderrText += text
        }
    }

    private func takeMessage(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = messages.firstIndex(where: { CodexLimitsReader.number($0["id"]) == id }) else {
            return nil
        }
        return messages.remove(at: index)
    }
}

enum WidgetError: Error, CustomStringConvertible {
    case authUnavailable
    case codexNotFound
    case invalidAuthToken
    case invalidOutput
    case missingRateLimits
    case serverError(String)
    case timeout

    var description: String {
        switch self {
        case .authUnavailable:
            return "open Codex Limits to sync auth"
        case .codexNotFound:
            return "codex was not found"
        case .invalidAuthToken:
            return "codex auth token is invalid"
        case .invalidOutput:
            return "invalid codex output"
        case .missingRateLimits:
            return "rate limits were not returned"
        case .serverError(let message):
            return message
        case .timeout:
            return "codex request timed out"
        }
    }
}

struct CodexLimitsWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexLimitsEntry
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 8 : 10) {
            header
            if let error = entry.limits.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            } else {
                if let primary = entry.limits.primary {
                    LimitRow(window: primary, resetDisplayStyle: resetDisplayStyle)
                }
                if let secondary = entry.limits.secondary {
                    LimitRow(window: secondary, resetDisplayStyle: resetDisplayStyle)
                }
                Spacer(minLength: 0)
                Text("Updated \(entry.limits.updatedAt, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 2)
        .containerBackground(.background, for: .widget)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Codex")
                .font(.headline.weight(.semibold))
            Spacer(minLength: 6)
            if let plan = entry.limits.plan {
                Text(plan.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.blue)
            }
        }
    }
}

struct LimitRow: View {
    let window: LimitWindow
    let resetDisplayStyle: ResetDisplayStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.name)
                    .font(.caption.weight(.semibold))
                Spacer(minLength: 8)
                Text(percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progressValue, total: 100)
                .tint(tint)
            if let resetDate = window.resetDate {
                Text(resetText(for: resetDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var percentText: String {
        if let remaining = window.remainingPercent {
            return "\(remaining)% left"
        }
        return "unknown"
    }

    private var progressValue: Double {
        Double(window.remainingPercent ?? 0)
    }

    private var tint: Color {
        guard let remaining = window.remainingPercent else {
            return .gray
        }
        if remaining <= 15 {
            return .red
        }
        if remaining <= 35 {
            return .orange
        }
        return .green
    }

    private func resetText(for date: Date) -> String {
        switch resetDisplayStyle {
        case .relative:
            return "resets in \(relativeResetText(until: date))"
        case .absolute:
            let formatter = DateFormatter()
            if Calendar.current.isDate(date, inSameDayAs: Date()) {
                formatter.setLocalizedDateFormatFromTemplate("HH:mm")
                return "resets at \(formatter.string(from: date))"
            }
            formatter.dateFormat = "dd.MM HH:mm"
            return "resets \(formatter.string(from: date))"
        }
    }

    private func relativeResetText(until date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(Date())))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            if hours > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(days)d"
        }
        if hours > 0 {
            if minutes > 0 {
                return "\(hours)h \(minutes)m"
            }
            return "\(hours)h"
        }
        return "\(minutes)m"
    }
}

struct CodexLimitsWidget: Widget {
    let kind = "CodexLimitsWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexLimitsWidgetView(entry: entry, resetDisplayStyle: .relative)
        }
        .configurationDisplayName("Codex Limits")
        .description("Shows the remaining Codex 5-hour and weekly limits.")
        .supportedFamilies([.systemSmall])
    }
}

struct CodexLimitsResetTimesWidget: Widget {
    let kind = "CodexLimitsResetTimesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodexLimitsProvider()) { entry in
            CodexLimitsWidgetView(entry: entry, resetDisplayStyle: .absolute)
        }
        .configurationDisplayName("Codex Reset Times")
        .description("Shows when the Codex 5-hour and weekly limits reset.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct CodexLimitsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexLimitsWidget()
        CodexLimitsResetTimesWidget()
    }
}
