import AppKit
import Foundation

@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case current
        case available(version: String, url: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.1"
    }

    var statusText: String {
        switch state {
        case .idle: "Ready to check"
        case .checking: "Checking for updates…"
        case .current: "Notch Agents is up to date"
        case .available(let version, _): "Version \(version) is available"
        case .failed(let message): message
        }
    }

    init() {
        lastChecked = UserDefaults.standard.object(forKey: "notchAgents.lastUpdateCheck") as? Date
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "notchAgents.automaticUpdates") == nil {
            defaults.set(true, forKey: "notchAgents.automaticUpdates")
        }
        guard defaults.bool(forKey: "notchAgents.automaticUpdates") else { return }
        let interval = defaults.string(forKey: "notchAgents.updateFrequency") ?? "Daily"
        let minimumAge: TimeInterval = interval == "Weekly" ? 604_800 : 86_400
        if lastChecked.map({ Date().timeIntervalSince($0) > minimumAge }) ?? true {
            Task { [weak self] in await self?.check(silent: true) }
        }
    }

    func check(silent: Bool = false) async {
        guard state != .checking else { return }
        state = .checking
        do {
            let channel = UserDefaults.standard.string(forKey: "notchAgents.updateChannel") ?? "Stable"
            let release = try await fetchRelease(includePrerelease: channel == "Preview")
            let checkedAt = Date()
            lastChecked = checkedAt
            UserDefaults.standard.set(checkedAt, forKey: "notchAgents.lastUpdateCheck")
            if let release, Self.isNewer(release.version, than: currentVersion) {
                state = .available(version: release.version, url: release.url)
            } else {
                state = .current
            }
        } catch {
            state = silent ? .idle : .failed("Couldn’t check for updates")
        }
    }

    func openDownload() {
        guard case .available(_, let url) = state else { return }
        NSWorkspace.shared.open(url)
    }

    private func fetchRelease(includePrerelease: Bool) async throws -> Release? {
        let endpoint = includePrerelease
            ? "https://api.github.com/repos/ishaanko/notch-agents/releases"
            : "https://api.github.com/repos/ishaanko/notch-agents/releases/latest"
        var request = URLRequest(url: URL(string: endpoint)!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Notch-Agents/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 404 { return nil }
        guard 200..<300 ~= http.statusCode else { throw URLError(.badServerResponse) }
        let decoder = JSONDecoder()
        if includePrerelease {
            let releases = try decoder.decode([GitHubRelease].self, from: data)
            return releases.first(where: { !$0.draft })?.release
        }
        return try decoder.decode(GitHubRelease.self, from: data).release
    }

    private static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = versionComponents(candidate)
        let rhs = versionComponents(current)
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func versionComponents(_ value: String) -> [Int] {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: ".")
            .map { component in
                Int(component.prefix(while: \.isNumber)) ?? 0
            }
    }
}

private struct Release {
    let version: String
    let url: URL
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: URL
    let draft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
    }

    var release: Release {
        Release(version: tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), url: htmlURL)
    }
}
