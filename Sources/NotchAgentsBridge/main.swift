import Foundation

struct Arguments {
    var source = "unknown"
    var event: String?
    var port: UInt16 = 18_989

    init(_ values: [String]) {
        var index = 1
        while index < values.count {
            switch values[index] {
            case "--source" where index + 1 < values.count:
                source = values[index + 1]
                index += 2
            case "--event" where index + 1 < values.count:
                event = values[index + 1]
                index += 2
            case "--port" where index + 1 < values.count:
                port = UInt16(values[index + 1]) ?? port
                index += 2
            case "--version":
                print("notch-agents-bridge 0.1.0")
                exit(0)
            default:
                index += 1
            }
        }
    }
}

let arguments = Arguments(CommandLine.arguments)
let input = FileHandle.standardInput.readDataToEndOfFile()
var payload: [String: Any] = [:]
if !input.isEmpty, let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any] {
    payload = object
} else if !input.isEmpty, let text = String(data: input, encoding: .utf8) {
    payload["message"] = text
}
payload["source"] = payload["source"] ?? arguments.source
if let event = arguments.event { payload["event"] = payload["event"] ?? event }
payload["bridge_pid"] = ProcessInfo.processInfo.processIdentifier
payload["received_at"] = ISO8601DateFormatter().string(from: Date())
let environment = ProcessInfo.processInfo.environment
if payload["terminal_session_id"] == nil {
    payload["terminal_session_id"] = environment["ITERM_SESSION_ID"] ?? environment["TERM_SESSION_ID"]
}
if payload["terminal_bundle_id"] == nil {
    let terminalProgram = (environment["TERM_PROGRAM"] ?? "").lowercased()
    if environment["ITERM_SESSION_ID"] != nil || terminalProgram.contains("iterm") {
        payload["terminal_bundle_id"] = "com.googlecode.iterm2"
    } else if terminalProgram.contains("ghostty") || environment["GHOSTTY_RESOURCES_DIR"] != nil {
        payload["terminal_bundle_id"] = "com.mitchellh.ghostty"
    } else if terminalProgram == "apple_terminal" {
        payload["terminal_bundle_id"] = "com.apple.Terminal"
    } else if terminalProgram.contains("warp") {
        payload["terminal_bundle_id"] = "dev.warp.Warp-Stable"
    } else if terminalProgram.contains("vscode") {
        payload["terminal_bundle_id"] = "com.microsoft.VSCode"
    } else if terminalProgram.contains("wezterm") {
        payload["terminal_bundle_id"] = "com.github.wez.wezterm"
    }
}

guard let body = try? JSONSerialization.data(withJSONObject: payload),
      let url = URL(string: "http://127.0.0.1:\(arguments.port)/event") else {
    exit(0)
}

let eventName = [
    payload["hook_event_name"], payload["event_name"], payload["event"], payload["type"],
]
    .compactMap { $0 as? String }
    .joined(separator: " ")
    .lowercased()
let isInteractive = eventName.contains("permission")
    || eventName.contains("approval")
    || eventName.contains("question")
    || eventName.contains("beforeshellexecution")
    || eventName.contains("beforemcpexecution")
    || ((payload["tool_name"] as? String)?.lowercased() == "askuserquestion")
let requestTimeout: TimeInterval = isInteractive
    ? (["claude", "claude-code", "droid", "factory", "qoder", "qwen", "codebuddy"].contains(arguments.source.lowercased())
        ? 86_400
        : 3_600)
    : 5
var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.httpBody = body

let semaphore = DispatchSemaphore(value: 0)
var responseData: Data?
URLSession.shared.dataTask(with: request) { data, _, error in
    if error == nil { responseData = data }
    semaphore.signal()
}.resume()

_ = semaphore.wait(timeout: .now() + requestTimeout + 2)

if let responseData,
   let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
   let output = response["output"] {
    if let string = output as? String {
        print(string)
    } else if JSONSerialization.isValidJSONObject(output),
              let data = try? JSONSerialization.data(withJSONObject: output),
              let string = String(data: data, encoding: .utf8) {
        print(string)
    }
}

exit(0)
