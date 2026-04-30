import Darwin
import Foundation
import SwiftUI
import WidgetKit

@main
struct CodexLimitsHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostView()
        }
        .windowResizability(.contentSize)
    }
}

struct HostView: View {
    @State private var status = "Preparing widget..."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Limits")
                .font(.title2.weight(.semibold))

            Text(status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Refresh Widget") {
                refreshWidget()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 420, alignment: .leading)
        .task {
            refreshWidget()
        }
    }

    private func refreshWidget() {
        do {
            let updatedAt = try AuthSnapshotWriter.write()
            WidgetCenter.shared.reloadAllTimelines()
            status = "Widget auth synced at \(DateFormatter.localizedString(from: updatedAt, dateStyle: .none, timeStyle: .short))"
        } catch {
            status = String(describing: error)
        }
    }
}

enum AuthSnapshotWriter {
    static func write() throws -> Date {
        let auth = try readCodexAuth()
        let updatedAt = Date()
        let destination = try authSnapshotURL()
        let directory = destination.deletingLastPathComponent()

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let payload: [String: Any] = [
            "accessToken": auth.accessToken,
            "accountId": auth.accountId,
            "planType": auth.planType,
            "updatedAt": Int(updatedAt.timeIntervalSince1970)
        ]
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        )

        try data.write(to: destination, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )

        return updatedAt
    }

    private static func readCodexAuth() throws -> ChatGPTAuthTokens {
        let authURL = URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json")
        let data = try Data(contentsOf: authURL)
        guard
            let auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = auth["tokens"] as? [String: Any],
            let accessToken = tokens["access_token"] as? String,
            let accountId = tokens["account_id"] as? String
        else {
            throw HostError.authUnavailable
        }

        guard let planType = chatGPTPlanType(from: accessToken)
            ?? (tokens["id_token"] as? String).flatMap(chatGPTPlanType(from:))
        else {
            throw HostError.invalidAuthToken
        }

        return ChatGPTAuthTokens(
            accessToken: accessToken,
            accountId: accountId,
            planType: planType
        )
    }

    private static func authSnapshotURL() throws -> URL {
        let widgetIdentifier = try widgetExtensionBundleIdentifier()
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: realHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)

        return libraryURL
            .appendingPathComponent("Containers", isDirectory: true)
            .appendingPathComponent(widgetIdentifier, isDirectory: true)
            .appendingPathComponent("Data", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexLimits", isDirectory: true)
            .appendingPathComponent("external-auth.json")
    }

    private static func widgetExtensionBundleIdentifier() throws -> String {
        let extensionURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("PlugIns", isDirectory: true)
            .appendingPathComponent("CodexLimitsWidgetExtension.appex", isDirectory: true)

        guard
            let bundle = Bundle(url: extensionURL),
            let identifier = bundle.bundleIdentifier,
            !identifier.isEmpty
        else {
            throw HostError.widgetExtensionUnavailable
        }

        return identifier
    }

    private static func realHomeDirectory() -> String {
        if
            let passwd = getpwuid(getuid()),
            let directory = passwd.pointee.pw_dir
        {
            let path = String(cString: directory)
            if !path.isEmpty {
                return path
            }
        }

        return NSHomeDirectory()
    }

    private static func chatGPTPlanType(from jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.count % 4
        if remainder > 0 {
            payload += String(repeating: "=", count: 4 - remainder)
        }

        guard
            let data = Data(base64Encoded: payload),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let auth = json["https://api.openai.com/auth"] as? [String: Any],
            let planType = auth["chatgpt_plan_type"] as? String
        else {
            return nil
        }

        return planType
    }
}

struct ChatGPTAuthTokens {
    let accessToken: String
    let accountId: String
    let planType: String
}

enum HostError: Error, CustomStringConvertible {
    case authUnavailable
    case invalidAuthToken
    case widgetExtensionUnavailable

    var description: String {
        switch self {
        case .authUnavailable:
            return "Codex auth is unavailable. Run `codex login` first."
        case .invalidAuthToken:
            return "Codex auth token is invalid. Run `codex login` again."
        case .widgetExtensionUnavailable:
            return "Codex Limits widget extension is unavailable. Reinstall the app."
        }
    }
}
