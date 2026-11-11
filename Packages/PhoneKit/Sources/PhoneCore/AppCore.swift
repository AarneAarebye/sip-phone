import Foundation
import Observation

@MainActor @Observable
public final class AppCore {
    public enum Connection: Equatable { case starting, connectingVPN, offline(String), authFailed, registering, ready, reconnecting }

    public struct ActiveCall: Equatable {
        public var id: Int
        public var remote: String
        public var displayName: String?
        public var isIncoming: Bool
        public var state: CallState
        public var serial: Int
        public var muted = false
    }

    public private(set) var connection: Connection = .starting
    public private(set) var contacts: [Contact] = []
    public private(set) var history: [CallRecord] = []
    public private(set) var activeCall: ActiveCall?
    public private(set) var phoneBookNotice: String?
    public private(set) var lastError: String?
    public private(set) var settings: AppSettings

    @ObservationIgnored private let sip: SIPEngine
    @ObservationIgnored private let phoneBook: PhoneBookService
    @ObservationIgnored private let vpn: VPNControlling
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let power: PowerAssertionControlling
    @ObservationIgnored private let cache: ContactCache
    @ObservationIgnored private let sipConfig: () -> SIPConfig?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var index = PhoneBookIndex(contacts: [])
    @ObservationIgnored private var startedVPN = false
    @ObservationIgnored private var onAC = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectGen = 0
    @ObservationIgnored private var callSerial = 0

    public init(sip: SIPEngine, phoneBook: PhoneBookService, vpn: VPNControlling, reachability: Reachability,
                power: PowerAssertionControlling, cache: ContactCache, settings: AppSettings,
                sipConfig: @escaping () -> SIPConfig?,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sip = sip; self.phoneBook = phoneBook; self.vpn = vpn; self.reachability = reachability
        self.power = power; self.cache = cache; self.settings = settings; self.sipConfig = sipConfig; self.sleep = sleep
        contacts = cache.load()   // offline still shows the saved book
        rebuildIndex()
    }

    // MARK: Lifecycle

    public func start() async { startEventLoop(); await connect(wake: false) }
    public func retry() async { await connect(wake: false) }
    public func handleWake() async { cancelReconnect(); await connect(wake: true) }

    public func shutdown() async {
        power.setPreventSleep(false)
        eventTask?.cancel(); eventTask = nil
        connectTask?.cancel(); connectTask = nil
        cleanupTask?.cancel(); cleanupTask = nil
        cancelReconnect()
        if let c = activeCall { sip.hangup(c.id) }
        sip.unregister()
        if startedVPN { await vpn.disconnect(); startedVPN = false }
    }

    /// Serialized: concurrent callers join the in-flight attempt instead of starting another.
    private func connect(wake: Bool) async {
        if let t = connectTask { await t.value; return }
        let t = Task { [weak self] in
            guard let self else { return }
            await self.runConnect(wake: wake)
            self.connectTask = nil
        }
        connectTask = t
        await t.value
    }

    private func runConnect(wake: Bool) async {
        cancelReconnect()
        // With an established registration or a call in progress, re-verify quietly (no UI flicker).
        let quiet = connection == .ready || activeCall != nil
        if !quiet { connection = .starting }
        func fail(_ msg: String) { if wake || quiet { startReconnect() } else { connection = .offline(msg) } }

        if !(await reachability.isFritzBoxReachable()) {
            guard !Task.isCancelled else { return }
            if !quiet { connection = .connectingVPN }
            startedVPN = true   // a partially started tunnel must still be torn down
            do { try await vpn.connect() }
            catch { if !Task.isCancelled { fail("VPN: \(error.localizedDescription)") }; return }
            guard !Task.isCancelled else { return }
            guard await reachability.isFritzBoxReachable() else {
                if !Task.isCancelled { fail("FRITZ!Box not reachable") }
                return
            }
        }
        guard !Task.isCancelled else { return }
        guard let cfg = sipConfig() else {
            await refreshPhoneBook()
            connection = .offline("Not configured – open Settings"); return
        }
        if !quiet { connection = .registering }
        // The phone book loads concurrently; it must not delay (or be delayed by) registration.
        async let book: Void = refreshPhoneBook()
        enum Outcome { case ok, auth, transient }
        let outcome: Outcome
        do { try await sip.register(cfg); outcome = .ok }
        catch SIPError.authFailed { outcome = .auth }
        catch { outcome = .transient }
        if !Task.isCancelled {
            switch outcome {
            case .ok: connection = .ready
            case .auth: connection = .authFailed
            case .transient: startReconnect()
            }
        }
        await book
    }

    private func startEventLoop() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, events = sip.events] in
            for await e in events { self?.handle(e) }
        }
    }

    // MARK: Phone book

    public func refreshPhoneBook() async {
        do {
            let c = try await phoneBook.loadContacts()
            contacts = c; cache.save(c); phoneBookNotice = nil
            rebuildIndex()
            history = (try? await phoneBook.loadCallList()) ?? history
        } catch {
            contacts = cache.load(); rebuildIndex()
            phoneBookNotice = "Phone book unavailable (\(error.localizedDescription)); showing saved copy."
        }
    }

    public func refreshHistory() async { if let h = try? await phoneBook.loadCallList() { history = h } }

    private func rebuildIndex() {
        index = PhoneBookIndex(contacts: contacts, countryCode: settings.countryCode,
                               areaCode: settings.areaCode.isEmpty ? nil : settings.areaCode)
    }

    // MARK: Events

    public func handle(_ event: SIPEvent) {
        switch event {
        case .incomingCall(let id, let remote):
            if let c = activeCall, !isEnded(c) { sip.hangup(id); return }   // busy: reject the second call
            beginCall(ActiveCall(id: id, remote: remote, displayName: index.name(for: remote), isIncoming: true, state: .ringing, serial: 0))
        case .callState(let id, let state):
            guard activeCall?.id == id else { return }
            activeCall?.state = state
            if case .ended(let code, let reason) = state {
                if code != 200 && code != 487 { lastError = "Call ended: \(code) \(reason)" }
                scheduleCallCleanup(activeCall?.serial ?? 0)
            }
        case .registration(.registered):
            guard connection != .authFailed else { return }
            cancelReconnect(); connection = .ready
        case .registration(.failed(let code, _)):
            if code == 401 || code == 403 { cancelReconnect(); connection = .authFailed }
            else if connection != .authFailed { startReconnect() }
        case .registration(.unregistered):
            break
        }
    }

    private func isEnded(_ c: ActiveCall) -> Bool { if case .ended = c.state { return true }; return false }

    private func beginCall(_ call: ActiveCall) {
        cleanupTask?.cancel(); cleanupTask = nil
        callSerial += 1
        var c = call; c.serial = callSerial
        activeCall = c
        sip.setMuted(false)
    }

    private func scheduleCallCleanup(_ serial: Int) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(2)
            guard !Task.isCancelled else { return }
            if self.activeCall?.serial == serial { self.activeCall = nil }
            await self.refreshHistory()
        }
    }
    public func waitForCallCleanup() async { await cleanupTask?.value }

    private func cancelReconnect() {
        reconnectTask?.cancel(); reconnectTask = nil; reconnectGen += 1
    }
    private func isCurrentReconnect(_ gen: Int) -> Bool { !Task.isCancelled && gen == reconnectGen }

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        connection = .reconnecting
        reconnectGen += 1
        let gen = reconnectGen
        reconnectTask = Task { [weak self] in
            var delay = 2.0
            while true {
                guard let self, self.isCurrentReconnect(gen) else { return }
                await self.sleep(delay)
                guard self.isCurrentReconnect(gen) else { return }
                if await self.reachability.isFritzBoxReachable() {
                    guard self.isCurrentReconnect(gen) else { return }
                    if let cfg = self.sipConfig() {
                        do {
                            try await self.sip.register(cfg)
                            guard self.isCurrentReconnect(gen) else { return }
                            self.connection = .ready; self.reconnectTask = nil; return
                        } catch SIPError.authFailed {
                            guard self.isCurrentReconnect(gen) else { return }
                            self.connection = .authFailed; self.reconnectTask = nil; return
                        } catch { /* keep retrying */ }
                    }
                } else {
                    // The tunnel may have dropped mid-session: bring it back, then re-probe on the next round.
                    self.startedVPN = true
                    try? await self.vpn.connect()
                }
                delay = min(delay * 2, 60)
            }
        }
    }
    public func waitForReconnect() async { await reconnectTask?.value }

    // MARK: Calls

    public func dial(_ number: String) {
        if let c = activeCall, !isEnded(c) { lastError = "Already in a call"; return }
        guard connection == .ready else { lastError = "Not connected"; return }
        do {
            let id = try sip.dial(number)
            beginCall(ActiveCall(id: id, remote: number, displayName: index.name(for: number), isIncoming: false, state: .calling, serial: 0))
        } catch { lastError = "Call failed: \(error.localizedDescription)" }
    }
    public func answer() { if let c = activeCall { sip.answer(c.id) } }
    public func hangup() { if let c = activeCall { sip.hangup(c.id) } }   // also declines an unanswered incoming call
    public func toggleMute() {
        guard var c = activeCall else { return }
        c.muted.toggle(); activeCall = c; sip.setMuted(c.muted)
    }
    public func sendDTMF(_ digits: String) { if let c = activeCall { sip.sendDTMF(digits, callId: c.id) } }
    public func clearError() { lastError = nil }
    public func reportError(_ message: String) { lastError = message }

    // MARK: Settings and power

    public func updateSettings(_ s: AppSettings) { settings = s; rebuildIndex(); applyPower() }
    public func powerSourceChanged(onAC: Bool) { self.onAC = onAC; applyPower() }
    private func applyPower() { power.setPreventSleep(onAC && settings.keepAwakeOnPower) }
}
