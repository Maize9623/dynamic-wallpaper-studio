import Foundation

enum LaunchAtLoginError: LocalizedError {
    case notInAppBundle
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notInAppBundle:
            return "请先把“动态壁纸工作室”放入应用程序文件夹，再开启登录启动。"
        case .commandFailed(let detail):
            return "无法更新登录启动项：\(detail)"
        }
    }
}

enum LaunchAtLoginController {
    static let label = "local.baiyaoyu.dynamicwallpaperstudio"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try enable()
        } else {
            try disable()
        }
    }

    private static func enable() throws {
        let executable = Bundle.main.executableURL
        guard let executable, Bundle.main.bundleURL.pathExtension == "app" else {
            throw LaunchAtLoginError.notInAppBundle
        }
        let parent = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let dictionary: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable.path, "--background"],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
            "LowPriorityIO": true,
            "ThrottleInterval": 10
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: dictionary,
            format: .xml,
            options: 0
        )
        try data.write(to: plistURL, options: .atomic)
        // Files in ~/Library/LaunchAgents are loaded at the next login.
        // Do not bootstrap here: doing so would launch a second copy while
        // the user is currently changing this setting.
    }

    private static func disable() throws {
        _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    @discardableResult
    private static func runLaunchctl(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw LaunchAtLoginError.commandFailed(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return text
    }
}
