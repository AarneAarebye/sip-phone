import AppKit
import IOKit.ps
import Network
import PhoneCore

/// Must be retained for the app lifetime (AppEnvironment holds it): the IOPS callback holds an unretained pointer.
@MainActor
public final class SystemMonitors {
    private let core: AppCore
    private var pathMonitor: NWPathMonitor?
    private var powerSource: CFRunLoopSource?
    private var wakeObserver: NSObjectProtocol?
    private var gate = PathChangeGate()
    private var debounce: Task<Void, Never>?

    public init(core: AppCore) { self.core = core }

    public func start() {
        guard pathMonitor == nil else { return }
        // Power source (AC vs battery)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<SystemMonitors>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in me.reportPower() }
        }, ctx)?.takeRetainedValue() {
            powerSource = src
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
        }
        reportPower()

        // Wake from sleep
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [core] _ in
            Task { @MainActor in await core.handleWake() }
        }

        // Network path changes (Wi-Fi switch, VPN up/down) -> re-register, debounced
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let sig = PathChangeGate.signature(interfaceNames: path.availableInterfaces.map(\.name), satisfied: path.status == .satisfied)
            Task { @MainActor in self?.pathChanged(sig) }
        }
        monitor.start(queue: .global())
        pathMonitor = monitor
    }

    /// Removes the run-loop source and observers and cancels the path monitor.
    public func stop() {
        if let src = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .defaultMode); powerSource = nil }
        if let o = wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); wakeObserver = nil }
        pathMonitor?.cancel(); pathMonitor = nil
        debounce?.cancel(); debounce = nil
    }

    private func reportPower() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        core.powerSourceChanged(onAC: PowerSourceInterpreter.isOnAC(providingType: type, acValue: kIOPSACPowerValue))
    }

    private func pathChanged(_ signature: String) {
        guard pathMonitor != nil, gate.observe(signature) else { return }
        debounce?.cancel()
        debounce = Task { [core] in
            try? await Task.sleep(for: PathChangeGate.debounce)
            if !Task.isCancelled, PathChangeGate.shouldReconnect(isConnectingVPN: core.connection == .connectingVPN) {
                await core.handleWake()
            }
        }
    }
}
