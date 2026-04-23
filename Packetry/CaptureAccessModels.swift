import Foundation

enum CaptureAccessBlocker: String, CaseIterable, Sendable, Equatable {
    case firstLaunch
    case helperMissing
    case helperBroken
    case accessDenied
    case noEligibleInterfaces
    case unsupportedInterface
    case upgradeRevalidation

    var title: String {
        switch self {
        case .firstLaunch:
            "Enable Live Capture"
        case .helperMissing:
            "Install Capture Access Helper"
        case .helperBroken:
            "Repair Capture Access Helper"
        case .accessDenied:
            "Capture Access Denied"
        case .noEligibleInterfaces:
            "No Eligible Interfaces"
        case .unsupportedInterface:
            "Unsupported Capture Source"
        case .upgradeRevalidation:
            "Re-check Capture Access"
        }
    }

    var detail: String {
        switch self {
        case .firstLaunch:
            "Packetry needs one guided setup step before macOS will allow non-root packet capture."
        case .helperMissing:
            "The boot-time helper that prepares /dev/bpf* access is not installed on this Mac."
        case .helperBroken:
            "Packetry found the helper contract, but /dev/bpf* is not in the expected state for capture."
        case .accessDenied:
            "This account still cannot access the macOS packet-capture devices after setup."
        case .noEligibleInterfaces:
            "Capture permissions are ready, but Packetry could not find a currently usable interface."
        case .unsupportedInterface:
            "The selected interface exists, but it does not match Packetry's current live-capture support contract."
        case .upgradeRevalidation:
            "Packetry was updated and needs to re-check helper installation plus interface inventory before capture resumes."
        }
    }

    func recommendedSteps() -> [CaptureOnboardingStep] {
        switch self {
        case .firstLaunch:
            [
                CaptureOnboardingStep(
                    title: "Install helper",
                    detail: "Run the guided setup so Packetry can prepare /dev/bpf* at boot without asking you to launch the app as root.",
                    actionLabel: "Install Helper"
                ),
                CaptureOnboardingStep(
                    title: "Re-check access",
                    detail: "After installation, Packetry verifies helper state and current capture permissions before enabling live capture.",
                    actionLabel: "Retry Check"
                ),
            ]
        case .helperMissing:
            [
                CaptureOnboardingStep(
                    title: "Install capture access",
                    detail: "Install the packaged LaunchDaemon so /dev/bpf* permissions are repaired automatically.",
                    actionLabel: "Install Helper"
                ),
            ]
        case .helperBroken:
            [
                CaptureOnboardingStep(
                    title: "Repair helper",
                    detail: "Reinstall or repair the helper package so macOS recreates /dev/bpf* with the expected permissions.",
                    actionLabel: "Repair"
                ),
                CaptureOnboardingStep(
                    title: "Retry capture check",
                    detail: "Ask Packetry to verify the helper and BPF devices again without restarting the entire app.",
                    actionLabel: "Retry"
                ),
            ]
        case .accessDenied:
            [
                CaptureOnboardingStep(
                    title: "Use an eligible account",
                    detail: "Packetry's current non-root capture path assumes a local admin-capable user account on this Mac.",
                    actionLabel: "Learn More"
                ),
            ]
        case .noEligibleInterfaces:
            [
                CaptureOnboardingStep(
                    title: "Refresh interfaces",
                    detail: "Retry interface discovery after network services finish coming online or VPN state changes.",
                    actionLabel: "Refresh"
                ),
                CaptureOnboardingStep(
                    title: "Open a file instead",
                    detail: "Offline analysis remains available even when no live interface is usable.",
                    actionLabel: "Open Capture"
                ),
            ]
        case .unsupportedInterface:
            [
                CaptureOnboardingStep(
                    title: "Pick a supported interface",
                    detail: "Use a standard supported network interface and keep specialty capture sources out of scope for now.",
                    actionLabel: "Choose Interface"
                ),
            ]
        case .upgradeRevalidation:
            [
                CaptureOnboardingStep(
                    title: "Revalidate setup",
                    detail: "Run Packetry's post-upgrade checks before re-enabling live capture controls.",
                    actionLabel: "Revalidate"
                ),
            ]
        }
    }
}

enum CaptureAccessState: Sendable, Equatable {
    case unknown
    case checking
    case blocked(CaptureAccessBlocker)
    case recovering
    case ready

    var isCaptureReady: Bool {
        if case .ready = self {
            return true
        }

        return false
    }

    var requiresGuidance: Bool {
        switch self {
        case .blocked, .recovering:
            true
        case .unknown, .checking, .ready:
            false
        }
    }

    var title: String {
        switch self {
        case .unknown:
            "Checking Capture Access"
        case .checking:
            "Checking Capture Access"
        case .blocked(let blocker):
            blocker.title
        case .recovering:
            "Retry Capture Access"
        case .ready:
            "Capture Access Ready"
        }
    }

    var detail: String {
        switch self {
        case .unknown, .checking:
            "Packetry is checking helper setup, /dev/bpf* access, and live interface availability."
        case .blocked(let blocker):
            blocker.detail
        case .recovering:
            "Packetry is waiting for you to retry after repairing setup or changing permissions."
        case .ready:
            "Packetry can enable supported live-capture workflows on this Mac."
        }
    }

    var recommendedSteps: [CaptureOnboardingStep] {
        switch self {
        case .blocked(let blocker):
            blocker.recommendedSteps()
        case .recovering:
            [
                CaptureOnboardingStep(
                    title: "Retry checks",
                    detail: "Ask Packetry to re-run helper, permission, and interface checks after the repair step finishes.",
                    actionLabel: "Retry"
                ),
            ]
        case .unknown, .checking, .ready:
            []
        }
    }
}

struct CaptureOnboardingStep: Identifiable, Sendable, Equatable {
    let id: String
    let title: String
    let detail: String
    let actionLabel: String

    init(title: String, detail: String, actionLabel: String) {
        self.id = title
        self.title = title
        self.detail = detail
        self.actionLabel = actionLabel
    }
}
