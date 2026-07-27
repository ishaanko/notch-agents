import AppKit
import SwiftUI

enum AppMotionPolicy {
    static let animationFPSPreferenceKey = "notchAgents.animationFPS"
    static let contentCrossfadeDuration: TimeInterval = 0.14

    static func reducesMotion(
        systemPreference: Bool,
        animationFPS: Int
    ) -> Bool {
        systemPreference || animationFPS <= 0
    }
}

private struct NotchReduceMotionEnvironmentKey: EnvironmentKey {
    static let defaultValue = false
}

private struct NotchAnimationActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var notchReduceMotion: Bool {
        get { self[NotchReduceMotionEnvironmentKey.self] }
        set { self[NotchReduceMotionEnvironmentKey.self] = newValue }
    }

    /// Hidden notch content remains mounted during the interruptible size
    /// transition. Pause its timelines once it is fully out of view.
    var notchAnimationActive: Bool {
        get { self[NotchAnimationActiveEnvironmentKey.self] }
        set { self[NotchAnimationActiveEnvironmentKey.self] = newValue }
    }
}

enum NotchTheme {
    static let notchNSColor = NSColor(
        colorSpace: .sRGB,
        components: [0, 0, 0, 1],
        count: 4
    )
    static let notchCGColor = notchNSColor.cgColor
    static let notchBlack = Color(nsColor: notchNSColor)

    static let openResponse: TimeInterval = 0.30
    static let closeResponse: TimeInterval = 0.24
    static let springDampingRatio = 1.0
    static let pressedScale = 0.97

    static let compactWidth: CGFloat = 256
    static let compactHeight: CGFloat = 32
    static let expandedWidth: CGFloat = 720
    static let maximumExpandedHeight: CGFloat = 520
    static let focusedQuestionMinimumHeight: CGFloat = 340
    static let focusedApprovalMinimumHeight: CGFloat = 280
    static let compactCornerRadius: CGFloat = 14
    static let expandedCornerRadius: CGFloat = 22
    static let sessionCornerRadius: CGFloat = 12
    static let expandedContentBottomInset: CGFloat = 16
    static let multiSessionFooterHeight: CGFloat = 34
    static let compactIconSize: CGFloat = 16
    static let expandedIconSize: CGFloat = 20

    static let background = Color(red: 0.035, green: 0.04, blue: 0.055)
    static let surface = Color(red: 0.075, green: 0.082, blue: 0.105)
    static let surfaceHigh = Color(red: 0.105, green: 0.115, blue: 0.145)
    static let cyan = Color(red: 0.28, green: 0.88, blue: 1.0)
    static let lime = Color(red: 0.65, green: 1.0, blue: 0.47)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.28)
    static let red = Color(red: 1.0, green: 0.35, blue: 0.42)
    static let muted = Color.white.opacity(0.55)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .running: cyan
        case .waiting, .idle: muted
        case .needsApproval, .question: amber
        case .completed: lime
        case .failed: red
        }
    }

    static func identityColor(agent: AgentKind, model: String? = nil) -> Color {
        if let model = model?.trimmingCharacters(in: .whitespacesAndNewlines),
           !model.isEmpty {
            return Color(
                hue: stableModelHue(model),
                saturation: 0.68,
                brightness: 0.98
            )
        }
        return Color(
            hue: providerHue(agent),
            saturation: agent == .unknown ? 0.18 : 0.72,
            brightness: agent == .unknown ? 0.82 : 0.98
        )
    }

    /// FNV-1a keeps model colors stable across launches; Swift's `Hasher` does not.
    static func stableModelHue(_ model: String) -> Double {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in model.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return Double(hash % 10_000) / 10_000
    }

    static func providerHue(_ agent: AgentKind) -> Double {
        switch agent {
        case .codex: 0.52
        case .claude: 0.055
        case .cursor: 0.76
        case .opencode: 0.39
        case .droid: 0.31
        case .kiro: 0.82
        case .copilot: 0.91
        case .antigravity: 0.58
        case .trae: 0.70
        case .qoder: 0.47
        case .qwen: 0.12
        case .kimi: 0.60
        case .deepseek: 0.67
        case .mistral: 0.025
        case .grok: 0.00
        case .zcode: 0.44
        case .mimocode: 0.16
        case .codebuddy: 0.35
        case .workbuddy: 0.22
        case .hermes: 0.095
        case .amp: 0.88
        case .pi: 0.73
        case .craft: 0.19
        case .conductor: 0.80
        case .t3code: 0.08
        case .warp: 0.72
        case .unknown: 0.56
        }
    }
}

/// One continuous silhouette shared by the black surface and content mask.
struct NotchSurfaceShape: InsettableShape {
    var cornerRadius: CGFloat
    private var insetAmount: CGFloat = 0

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
    }

    func path(in rect: CGRect) -> Path {
        let insetRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let radius = max(0, cornerRadius - insetAmount)
        return UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .path(in: insetRect)
    }

    func inset(by amount: CGFloat) -> NotchSurfaceShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct PixelText: ViewModifier {
    var size: CGFloat
    var weight: Font.Weight = .medium
    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: .rounded))
    }
}

extension View {
    func pixelText(_ size: CGFloat, weight: Font.Weight = .medium) -> some View {
        modifier(PixelText(size: size, weight: weight))
    }
}

enum AgentBrandIconRole: Sendable {
    case application
    case company
}

/// Central resolver for real installed app artwork and bundled provider marks.
/// Settings, onboarding, and the notch should all use this instead of `AgentKind.glyph`.
enum BrandIconResolver {
    @MainActor private static var appIconCache: [AgentKind: NSImage] = [:]
    @MainActor private static var resolvedAppIcons: Set<AgentKind> = []
    @MainActor private static var companyMarkCache: [AgentKind: NSImage] = [:]
    @MainActor private static var resolvedCompanyMarks: Set<AgentKind> = []

    @MainActor
    static func image(
        for agent: AgentKind,
        role: AgentBrandIconRole = .application
    ) -> NSImage? {
        if role == .application, let icon = appIcon(for: agent) {
            return icon
        }
        if let mark = companyMark(for: agent) {
            return mark
        }
        return appIcon(for: agent)
    }

    @MainActor
    static func appIcon(for agent: AgentKind) -> NSImage? {
        if resolvedAppIcons.contains(agent) {
            return appIconCache[agent]
        }
        resolvedAppIcons.insert(agent)
        for bundleIdentifier in bundleIdentifiers(for: agent) {
            if let url = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: bundleIdentifier
            ) {
                let image = NSWorkspace.shared.icon(forFile: url.path)
                appIconCache[agent] = image
                return image
            }
        }

        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true),
        ]
        for name in applicationNames(for: agent) {
            for root in roots {
                let url = root.appendingPathComponent("\(name).app", isDirectory: true)
                if FileManager.default.fileExists(atPath: url.path) {
                    let image = NSWorkspace.shared.icon(forFile: url.path)
                    appIconCache[agent] = image
                    return image
                }
            }
        }
        return nil
    }

    static func providerName(for agent: AgentKind) -> String {
        switch agent {
        case .codex: "OpenAI"
        case .claude: "Anthropic"
        case .antigravity: "Google"
        case .cursor: "Cursor"
        case .warp: "Warp"
        case .copilot: "GitHub"
        default: agent.displayName
        }
    }

    @MainActor
    private static func companyMark(for agent: AgentKind) -> NSImage? {
        if resolvedCompanyMarks.contains(agent) {
            return companyMarkCache[agent]
        }
        resolvedCompanyMarks.insert(agent)
        guard let resource = companyAssetName(for: agent),
              let url = resourceURL(named: resource),
              let image = NSImage(contentsOf: url),
              let copy = image.copy() as? NSImage else { return nil }
        copy.isTemplate = true
        companyMarkCache[agent] = copy
        return copy
    }

    private static func companyAssetName(for agent: AgentKind) -> String? {
        switch agent {
        case .codex: "openai"
        case .claude: "anthropic"
        case .antigravity: "antigravity"
        case .cursor: "cursor"
        case .warp: "warp"
        default: nil
        }
    }

    @MainActor
    private static func resourceURL(named name: String) -> URL? {
        let packagedBundle = Bundle.main.resourceURL
            .map { $0.appendingPathComponent("NotchAgents_NotchAgents.bundle") }
            .flatMap(Bundle.init(url:))
        return packagedBundle?.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Brands"
        )
            ?? packagedBundle?.url(forResource: name, withExtension: "svg")
            ?? Bundle.module.url(
                forResource: name,
                withExtension: "svg",
                subdirectory: "Brands"
            )
            ?? Bundle.module.url(forResource: name, withExtension: "svg")
    }

    private static func bundleIdentifiers(for agent: AgentKind) -> [String] {
        switch agent {
        case .codex: ["com.openai.codex"]
        case .claude: ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .antigravity: ["com.google.antigravity"]
        case .cursor: ["com.todesktop.230313mzl4w4u92"]
        case .warp: ["dev.warp.Warp-Stable"]
        case .kiro: ["dev.kiro.desktop"]
        default: []
        }
    }

    private static func applicationNames(for agent: AgentKind) -> [String] {
        AgentIntegrationCatalog.descriptor(for: agent)?.applicationNames.map {
            $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0
        } ?? [agent.displayName]
    }
}

struct AgentBrandIcon: View {
    let agent: AgentKind
    var size: CGFloat
    var role: AgentBrandIconRole = .application

    var body: some View {
        Group {
            if let image = BrandIconResolver.image(for: agent, role: role) {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(image.isTemplate ? .template : .original)
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: max(3, size * 0.28), style: .continuous)
                        .fill(NotchTheme.identityColor(agent: agent).opacity(0.2))
                    RoundedRectangle(cornerRadius: max(3, size * 0.28), style: .continuous)
                        .stroke(NotchTheme.identityColor(agent: agent).opacity(0.55), lineWidth: 0.75)
                    Text(agent.identityMark)
                        .font(.system(
                            size: max(5, size * (agent.identityMark.count > 2 ? 0.28 : 0.34)),
                            weight: .bold,
                            design: .rounded
                        ))
                        .minimumScaleFactor(0.65)
                        .foregroundStyle(NotchTheme.identityColor(agent: agent))
                        .padding(size * 0.12)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(
            role == .company
                ? BrandIconResolver.providerName(for: agent)
                : agent.displayName
        )
    }
}
