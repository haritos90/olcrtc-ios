import SwiftUI

// #263: The single-source VPS display model + its pure reducer, moved out of
// ServersView (introduced in #258, reducer extracted in #259). The View drives
// these transitions; `HostDisplayTests` covers them. The "no status-jump"
// invariants live here:
//   • a probe result is the ONLY thing that sets the base (terminalBase),
//   • while running the card shows the PREVIOUS base, never the optimistic target,
//   • phases advance forward only (advanced), capped at the last milestone,
//   • a failure carries previousBase so Retry (retryBase) can restore it.

/// What the server IS. Set ONLY from a confirmed probe — never optimistically
/// mid-operation. Maps from `VPSReadinessState`.
enum HostBase: Equatable {
    case unknown, noPodman, noImage, imageReady, stopped, running

    init(_ r: VPSReadinessState) {
        switch r {
        case .noPodman:         self = .noPodman
        case .noImage:          self = .noImage
        case .imageReady:       self = .imageReady
        case .containerStopped: self = .stopped
        case .containerRunning: self = .running
        }
    }

    var hasContainer: Bool { self == .running || self == .stopped }

    var tone: OlcStatusTone {
        switch self {
        case .unknown, .noPodman:   return .unknown
        case .noImage:              return .progress   // amber — Podman ok, image not pulled
        case .imageReady, .running: return .ok
        case .stopped:              return .warn
        }
    }
    var title: String {
        switch self {
        case .unknown:    return L10n.vpsTitleUnknown.localized()
        case .noPodman:   return L10n.vpsTitleReady.localized()
        case .noImage:    return L10n.vpsTitlePodmanReady.localized()
        case .imageReady: return L10n.vpsTitleReady.localized()
        case .stopped:    return L10n.vpsTitleStopped.localized()
        case .running:    return L10n.vpsTitleRunning.localized()
        }
    }
    var subtitle: String {
        switch self {
        case .unknown:    return L10n.vpsSubUnknown.localized()
        case .noPodman:   return L10n.vpsSubNoPodman.localized()
        case .noImage:    return L10n.vpsSubNoImage.localized()
        case .imageReady: return L10n.vpsSubImageReady.localized()
        case .stopped:    return L10n.vpsSubStopped.localized()
        case .running:    return L10n.vpsSubRunning.localized()
        }
    }
}

/// What we're DOING. `stepCount` sizes the progress-bar denominator (the live
/// provisioner message is the running subtitle); `target` is the nominal resolved
/// state used only when an op doesn't probe.
enum HostOp: Equatable {
    case check, install, start, stop, reconfigure, update, uninstall, deepUninstall, reboot

    var verb: String {
        switch self {
        case .check:         return L10n.vpsVerbChecking.localized()
        case .install:       return L10n.vpsVerbInstalling.localized()
        case .start:         return L10n.vpsVerbStarting.localized()
        case .stop:          return L10n.vpsVerbStopping.localized()
        case .reconfigure:   return L10n.vpsVerbReconfiguring.localized()
        case .update:        return L10n.vpsVerbUpdating.localized()
        case .uninstall:     return L10n.vpsVerbUninstalling.localized()
        case .deepUninstall: return L10n.vpsVerbDeepUninstalling.localized()
        case .reboot:        return L10n.vpsVerbRebooting.localized()
        }
    }

    /// Number of progress milestones — sizes the bar denominator only. The
    /// displayed running subtitle is the live (localized) provisioner message,
    /// not a fixed phase label, so individual step strings aren't needed.
    var stepCount: Int {
        switch self {
        case .check:  return 2
        case .install: return 5
        case .update: return 4
        case .start, .stop, .reconfigure, .uninstall, .deepUninstall, .reboot: return 3
        }
    }

    var target: HostBase? {
        switch self {
        case .check, .reboot:                          return nil      // keep previous base
        case .install, .start, .reconfigure, .update:  return .running
        case .stop:                                    return .stopped
        case .uninstall:                               return .imageReady
        case .deepUninstall:                           return .noPodman
        }
    }
}

/// The ONE display state. The card computes everything (status pill, progress bar,
/// primary button, menu) from this. `previousBase` rides along so Retry / a
/// no-probe success can restore without a second source.
enum HostDisplay: Equatable {
    case base(HostBase)
    case running(op: HostOp, phase: Int, note: String, previousBase: HostBase)
    case failed(op: HostOp, phase: String, message: String, previousBase: HostBase)
}

// MARK: - Reducer (pure — unit-tested in HostDisplayTests)

extension HostBase {
    /// Pre-probe seed for a never-probed host: a known container → `.stopped`
    /// (offer Start, never a mistaken reinstall); otherwise `.unknown` ("tap
    /// Check"). Never asserts `.running` without a probe.
    static func seed(lastContainerName: String?) -> HostBase {
        lastContainerName != nil ? .stopped : .unknown
    }
}

extension HostDisplay {
    /// The confirmed base under whatever is shown. Running / failed keep the base
    /// they started from — so the card never shows an optimistic state mid-op.
    var base: HostBase {
        switch self {
        case .base(let b):                return b
        case .running(_, _, _, let prev): return prev
        case .failed(_, _, _, let prev):  return prev
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// Begin an operation from a confirmed base: phase 0, first milestone note.
    static func start(_ op: HostOp, from base: HostBase) -> HostDisplay {
        .running(op: op, phase: 0, note: L10n.vpsConnecting.localized(), previousBase: base)
    }

    /// Advance a running operation: phase forward only (capped at the last
    /// milestone) + the live note. Non-running states pass through unchanged.
    func advanced(note: String) -> HostDisplay {
        guard case .running(let op, let phase, _, let prev) = self else { return self }
        let next = min(phase + 1, max(op.stepCount - 1, 0))
        return .running(op: op, phase: next, note: note, previousBase: prev)
    }

    /// The ONE terminal base on success: the probe result wins; else the op's
    /// nominal target; else the base we started from. Only a real probe should
    /// pass a non-nil `probed`.
    static func terminalBase(op: HostOp, probed: HostBase?, previous: HostBase) -> HostBase {
        probed ?? op.target ?? previous
    }

    /// Terminal failure: keep the op + the note where it failed, carry the
    /// previous base for Retry. Non-running → unchanged.
    func failed(message: String) -> HostDisplay {
        guard case .running(let op, _, let note, let prev) = self else { return self }
        return .failed(op: op, phase: note, message: message, previousBase: prev)
    }

    /// What Retry restores before re-dispatching the op: the base under a failure.
    func retryBase() -> HostDisplay? {
        guard case .failed(_, _, _, let prev) = self else { return nil }
        return .base(prev)
    }
}
