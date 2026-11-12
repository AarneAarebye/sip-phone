// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright © 2026 Aarne Aarebye

import Foundation
import Observation
import os

@MainActor @Observable
public final class AppCore {
    public enum Connection: Equatable { case starting, connectingVPN, offline(String), authFailed, registering, ready, reconnecting }

    /// Timing of the "am I home?" check while the app's own tunnel is up.
    public struct HomeCheckTiming: Sendable {
        /// Pause between periodic checks.
        public var interval: TimeInterval
        /// Pause between the direct probes of one check.
        public var confirmDelay: TimeInterval
        /// Direct probes in a row that must succeed before the tunnel is stopped (hysteresis while switching Wi-Fi).
        public var confirmations: Int
        public init(interval: TimeInterval = 20, confirmDelay: TimeInterval = 3, confirmations: Int = 2) {
            self.interval = interval; self.confirmDelay = confirmDelay; self.confirmations = confirmations
        }
    }
    public static let homeNotice = "VPN off – you are home"
    /// Refusal shown by `dial` while a call is live; points at the "In call" row of the popover.
    public static let alreadyInCall = "Already in a call – end the current call first (Hang up in the In call row above)"

    /// Timing of the call watchdogs.
    public struct CallWatchTiming: Sendable {
        /// Pause between checks that the engine still knows the active call.
        public var reconcileInterval: TimeInterval
        /// After a local hang-up, wait this long for the end event before ending the call locally.
        public var hangupTimeout: TimeInterval
        public init(reconcileInterval: TimeInterval = 3, hangupTimeout: TimeInterval = 4) {
            self.reconcileInterval = reconcileInterval; self.hangupTimeout = hangupTimeout
        }
    }

    public struct ActiveCall: Equatable {
        public var id: Int
        public var remote: String
        public var displayName: String?
        public var calledNumber: String?
        public var isIncoming: Bool
        public var state: CallState
        public var serial: Int
        public var muted = false
        /// Negotiated telephone-event info, once the audio is active.
        public var media: CallMediaInfo?
        /// Outcome of the last keypad press (never the digits); `dtmfSerial` increments with every press.
        public var dtmfStatus: String?
        public var dtmfSerial = 0
        /// True once the call reached `.connected`.
        public var wasConnected = false
        /// True when this app initiated the end (hang up, cancel or decline).
        public var endedLocally = false
        /// User-facing wording once the call has ended.
        public var endMessage: String?
        /// When the call reached `.connected` (for the call timer).
        public var connectedAt: Date?
    }

    public private(set) var connection: Connection = .starting
    public private(set) var contacts: [Contact] = []
    /// All known phone books (including switched-off ones).
    public var phoneBooks: [PhoneBookSummary] { PhoneBooks.summaries(from: contacts) }
    /// Contacts of switched-on books only.
    public var visibleContacts: [Contact] { PhoneBooks.visible(contacts, disabled: settings.disabledPhoneBooks) }
    public private(set) var history: [CallRecord] = []
    public private(set) var activeCall: ActiveCall?
    public private(set) var phoneBookNotice: String?
    public private(set) var lastError: String?
    public private(set) var settings: AppSettings
    /// Telephone-event summary of the most recent call's audio (Settings > Diagnostics); survives the call.
    public private(set) var lastCallMedia: String?
    /// Short informational status about the VPN (e.g. it was switched off because the Mac is home). Not an error.
    public private(set) var vpnNotice: String?

    @ObservationIgnored private let sip: SIPEngine
    @ObservationIgnored private let phoneBook: PhoneBookService
    @ObservationIgnored private let vpn: VPNControlling
    @ObservationIgnored private let reachability: Reachability
    @ObservationIgnored private let power: PowerAssertionControlling
    @ObservationIgnored private let cache: ContactCache
    @ObservationIgnored private let sipConfig: () -> SIPConfig?
    @ObservationIgnored private let phoneBookFailureDetail: () -> String?
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let homeSleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private let homeTiming: HomeCheckTiming
    @ObservationIgnored private var homeWatchTask: Task<Void, Never>?
    @ObservationIgnored private var homeCheckTask: Task<Bool, Never>?
    @ObservationIgnored private var homeCheckAfterCall = false
    /// The network path changed since the SIP transport was last rebound (handleIpChange pending).
    @ObservationIgnored private var pathChanged = false
    @ObservationIgnored private var index = PhoneBookIndex(contacts: [])
    @ObservationIgnored private var startedVPN = false
    @ObservationIgnored private var onAC = false
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var connectTask: Task<Void, Never>?
    @ObservationIgnored private var connectGen = 0
    @ObservationIgnored private var bookTask: Task<Void, Never>?
    @ObservationIgnored private var reRegisterAfterCall = false
    @ObservationIgnored private var vpnError: String?
    @ObservationIgnored private var reconnectGen = 0
    @ObservationIgnored private var callSerial = 0
    @ObservationIgnored private let callTiming: CallWatchTiming
    @ObservationIgnored private let callSleep: @Sendable (TimeInterval) async -> Void
    @ObservationIgnored private var reconcileTask: Task<Void, Never>?
    @ObservationIgnored private var hangupWatchTask: Task<Void, Never>?

    public init(sip: SIPEngine, phoneBook: PhoneBookService, vpn: VPNControlling, reachability: Reachability,
                power: PowerAssertionControlling, cache: ContactCache, settings: AppSettings,
                sipConfig: @escaping () -> SIPConfig?,
                phoneBookFailureDetail: @escaping () -> String? = { nil },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                homeTiming: HomeCheckTiming = HomeCheckTiming(),
                homeSleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                callTiming: CallWatchTiming = CallWatchTiming(),
                callSleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sip = sip; self.phoneBook = phoneBook; self.vpn = vpn; self.reachability = reachability
        self.power = power; self.cache = cache; self.settings = settings; self.sipConfig = sipConfig; self.sleep = sleep
        self.homeTiming = homeTiming; self.homeSleep = homeSleep
        self.callTiming = callTiming; self.callSleep = callSleep
        self.phoneBookFailureDetail = phoneBookFailureDetail
        contacts = cache.load()   // offline still shows the saved book
        rebuildIndex()
    }

    // MARK: Lifecycle

    /// Returns once the first connect attempt and the first phone-book load are done.
    public func start() async { startEventLoop(); await connect(wake: false); await bookTask?.value }
    public func retry() async { await connect(wake: false) }
    /// Wake from sleep and debounced network-path changes. With the app's own tunnel up, first checks whether the
    /// Mac is home (then the tunnel is stopped and the connection re-established without it).
    public func handleWake() async {
        // A call the engine no longer knows must not hold the network-change handling back. Its deferred work
        // is done right here, so it is not queued a second time.
        if reconcile(trigger: "network change", runDeferred: false) { reRegisterAfterCall = false }
        pathChanged = true
        if deferWhileInCall() { return }
        homeCheckAfterCall = false
        if startedVPN, await checkHome() { return }
        cancelReconnect(); await connect(wake: true)
    }

    private var callIsLive: Bool { activeCall.map { !isEnded($0) } ?? false }

    /// A live call must not be disturbed by a re-registration (wake, network change, Settings save):
    /// remember the request and re-register once the call has ended.
    private func deferWhileInCall() -> Bool {
        guard callIsLive else { return false }
        if !reRegisterAfterCall { CallLog.logger.info("call #\(self.activeCall?.serial ?? 0, privacy: .public) live: network change / re-registration deferred until it ends") }
        reRegisterAfterCall = true
        return true
    }

    public func shutdown() async {
        power.setPreventSleep(false)
        eventTask?.cancel(); eventTask = nil
        connectTask?.cancel(); connectTask = nil
        cleanupTask?.cancel(); cleanupTask = nil
        stopCallWatch()
        stopHomeWatch()
        homeCheckTask?.cancel(); homeCheckTask = nil
        homeCheckAfterCall = false
        bookTask?.cancel()   // clears itself when it finishes
        reRegisterAfterCall = false
        cancelReconnect()
        if let c = activeCall {
            CallLog.logger.info("call #\(c.serial, privacy: .public) hang up by shutdown (id \(c.id, privacy: .public)); activeCall cleared (shutdown)")
            sip.hangup(c.id)
            activeCall = nil
        }
        sip.unregister()
        if startedVPN { await vpn.disconnect(); startedVPN = false }
    }

    /// Serialized: concurrent callers join the in-flight attempt instead of starting another.
    private func connect(wake: Bool) async {
        if deferWhileInCall() { return }
        if let t = connectTask { await t.value; return }
        connectGen += 1
        let gen = connectGen
        let t = Task { [weak self] in
            guard let self else { return }
            await self.runConnect(wake: wake)
            if self.connectGen == gen { self.connectTask = nil }   // never clear a newer attempt (shutdown + start)
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

        // Never start the VPN at home: a box that answers directly needs no tunnel.
        if !(await reachability.isFritzBoxReachable()), !(await reachability.isFritzBoxReachableDirectly()) {
            guard !Task.isCancelled else { return }
            if !quiet { connection = .connectingVPN }
            startedVPN = true   // a partially started tunnel must still be torn down
            startHomeWatch()
            do { try await vpn.connect() }
            catch is CancellationError { return }   // stopped on purpose
            catch { if !Task.isCancelled { fail("VPN: \(error.localizedDescription)") }; return }
            guard !Task.isCancelled else { return }
            vpnStarted()
            guard await reachability.isFritzBoxReachable() else {
                if !Task.isCancelled { fail("FRITZ!Box not reachable") }
                return
            }
        }
        guard !Task.isCancelled else { return }
        applyNetworkChange()
        guard let cfg = sipConfig() else {
            startPhoneBookRefresh()
            connection = .offline("Not configured – open Settings"); return
        }
        if !quiet { connection = .registering }
        // The phone book loads in its own task: a slow or hung TR-064 request must neither delay registration
        // nor keep this (serialized) attempt alive for later wake/retry callers to join.
        startPhoneBookRefresh()
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
    }

    private func startEventLoop() {
        guard eventTask == nil else { return }
        eventTask = Task { [weak self, events = sip.events] in
            for await e in events { self?.handle(e) }
        }
    }

    // MARK: Phone book

    private func startPhoneBookRefresh() {
        guard bookTask == nil else { return }   // one refresh at a time
        bookTask = Task { [weak self] in
            await self?.refreshPhoneBook()
            self?.bookTask = nil
        }
    }
    public func waitForPhoneBook() async { await bookTask?.value }

    public func refreshPhoneBook() async {
        do {
            let c = try await phoneBook.loadContacts()
            contacts = c; cache.save(c); phoneBookNotice = nil
            rebuildIndex()
            history = (try? await phoneBook.loadCallList()) ?? history
        } catch {
            contacts = cache.load(); rebuildIndex()
            phoneBookNotice = "Phone book unavailable (\(error.localizedDescription)); showing saved copy."
                + (phoneBookFailureDetail().map { " (\($0))" } ?? "")   // short, sanitized transport detail
        }
    }

    public func refreshHistory() async { if let h = try? await phoneBook.loadCallList() { history = h } }

    private func rebuildIndex() {
        index = PhoneBookIndex(contacts: visibleContacts, countryCode: settings.countryCode,
                               areaCode: settings.areaCode.isEmpty ? nil : settings.areaCode)
    }

    // MARK: Events

    public func handle(_ event: SIPEvent) {
        switch event {
        case .incomingCall(let id, let remote, let called):
            if let c = activeCall, !isEnded(c) { reconcile(trigger: "incoming call", runDeferred: true) }
            if let c = activeCall, !isEnded(c) {   // busy: reject the second call
                CallLog.logger.info("incoming call (id \(id, privacy: .public)) rejected: call #\(c.serial, privacy: .public) is live")
                sip.hangup(id); return
            }
            beginCall(ActiveCall(id: id, remote: remote, displayName: index.name(for: remote), calledNumber: called, isIncoming: true, state: .ringing, serial: 0))
        case .callState(let id, let state):
            guard let c = activeCall, c.id == id else {
                CallLog.logger.info("state \(Self.describe(state), privacy: .public) for id \(id, privacy: .public) ignored: active call is \(self.activeCall.map { "#\($0.serial) id \($0.id)" } ?? "none", privacy: .public)")
                return
            }
            guard !isEnded(c) else {
                CallLog.logger.info("call #\(c.serial, privacy: .public) state \(Self.describe(state), privacy: .public) ignored: already ended")
                return
            }
            CallLog.logger.info("call #\(c.serial, privacy: .public) state \(Self.describe(state), privacy: .public) (id \(id, privacy: .public))")
            if case .ended(let code, let reason) = state {
                callEnded(code: code, reason: reason, forcedMessage: nil, runDeferred: true)
            } else {
                activeCall?.state = state
                if case .connected = state, !c.wasConnected { activeCall?.wasConnected = true; activeCall?.connectedAt = Date() }
            }
        case .callMedia(let id, let info):
            guard activeCall?.id == id else {
                CallLog.logger.info("media event for id \(id, privacy: .public) ignored: not the active call")
                return
            }
            activeCall?.media = info
            lastCallMedia = info.summary
            DTMFLog.logger.info("Call media active: \(info.summary, privacy: .public)")
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

    static func describe(_ s: CallState) -> String {
        switch s {
        case .calling: return "calling"
        case .ringing: return "ringing"
        case .connected: return "connected"
        case .ended(let code, let reason): return "ended \(code) \(reason)"
        }
    }

    private func beginCall(_ call: ActiveCall) {
        cleanupTask?.cancel(); cleanupTask = nil
        callSerial += 1
        var c = call; c.serial = callSerial
        if let old = activeCall {
            CallLog.logger.info("call #\(old.serial, privacy: .public) replaced by call #\(c.serial, privacy: .public) (activeCall cleared: new call)")
        }
        activeCall = c
        CallLog.logger.info("call #\(c.serial, privacy: .public) activeCall set: \(c.isIncoming ? "incoming" : "outgoing", privacy: .public), id \(c.id, privacy: .public), state \(Self.describe(c.state), privacy: .public)")
        sip.setMuted(false)
        startCallWatch(serial: c.serial)
    }

    /// Ends the active call: wording, error, cleanup timer, watchdogs, deferred network-change work.
    /// `forcedMessage`: the call was ended locally because the engine's end event is missing.
    private func callEnded(code: Int, reason: String, forcedMessage: String?, runDeferred: Bool) {
        guard let c = activeCall else { return }
        activeCall?.state = .ended(code: code, reason: reason)
        stopCallWatch()
        if let m = forcedMessage {
            activeCall?.endMessage = m
        } else {
            let d = CallEndDescription.describe(code: code, reason: reason, isIncoming: c.isIncoming,
                                                wasConnected: c.wasConnected, endedLocally: c.endedLocally)
            activeCall?.endMessage = d.text
            if d.isError { lastError = d.text }
        }
        CallLog.logger.info("call #\(c.serial, privacy: .public) ended (\(code, privacy: .public) \(reason, privacy: .public)); end message: \(self.activeCall?.endMessage ?? "", privacy: .public)")
        scheduleCallCleanup(c.serial)
        guard runDeferred else { return }
        if reRegisterAfterCall {
            reRegisterAfterCall = false
            CallLog.logger.info("call #\(c.serial, privacy: .public) deferred network-change handling: run")
            Task { [weak self] in await self?.handleWake() }   // includes a deferred home check
        } else if homeCheckAfterCall {
            homeCheckAfterCall = false
            CallLog.logger.info("call #\(c.serial, privacy: .public) deferred home check: run")
            Task { [weak self] in _ = await self?.checkHome() }
        }
    }

    /// The engine no longer knows the live active call (its end event was lost): end it as "Call ended".
    /// Returns true when it ended the call.
    @discardableResult
    private func reconcile(trigger: String, runDeferred: Bool) -> Bool {
        guard let c = activeCall, !isEnded(c), !sip.isCallActive(c.id) else { return false }
        CallLog.logger.error("call #\(c.serial, privacy: .public) reconcile (\(trigger, privacy: .public)): engine lost the call (id \(c.id, privacy: .public)); ending it locally")
        callEnded(code: 0, reason: "engine lost the call", forcedMessage: "Call ended", runDeferred: runDeferred)
        return true
    }

    /// Every `reconcileInterval` while the call is live: reconcile with the engine. Ends with the call.
    private func startCallWatch(serial: Int) {
        stopCallWatch()
        let interval = callTiming.reconcileInterval
        reconcileTask = Task { [weak self, callSleep] in
            while true {
                await callSleep(interval)
                guard !Task.isCancelled, let self, let c = self.activeCall, c.serial == serial, !self.isEnded(c) else { return }
                self.reconcile(trigger: "tick", runDeferred: true)
            }
        }
    }

    private func stopCallWatch() {
        reconcileTask?.cancel(); reconcileTask = nil
        hangupWatchTask?.cancel(); hangupWatchTask = nil
    }

    /// After a local hang-up: without an end event within `hangupTimeout`, end the call locally and make the
    /// engine destroy it (e.g. a BYE whose response never arrives keeps PJSIP's call alive for 32 s).
    private func startHangupWatch(serial: Int) {
        hangupWatchTask?.cancel()
        let timeout = callTiming.hangupTimeout
        hangupWatchTask = Task { [weak self, callSleep] in
            await callSleep(timeout)
            guard !Task.isCancelled, let self, let c = self.activeCall, c.serial == serial, !self.isEnded(c) else { return }
            CallLog.logger.error("call #\(c.serial, privacy: .public) no end event \(timeout, privacy: .public) s after local hang up (id \(c.id, privacy: .public), engine active: \(self.sip.isCallActive(c.id), privacy: .public)); forcing the end")
            self.callEnded(code: 0, reason: "no end event after hang up", forcedMessage: "Call ended", runDeferred: true)
            self.sip.forceEnd(c.id)
        }
    }

    private func scheduleCallCleanup(_ serial: Int) {
        cleanupTask?.cancel()
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(2)
            guard !Task.isCancelled else { return }
            if self.activeCall?.serial == serial {
                self.activeCall = nil
                CallLog.logger.info("call #\(serial, privacy: .public) activeCall cleared (cleanup timer)")
            }
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
                        self.applyNetworkChange()
                        do {
                            try await self.sip.register(cfg)
                            guard self.isCurrentReconnect(gen) else { return }
                            if let v = self.vpnError, self.lastError == v { self.lastError = nil }
                            self.vpnError = nil
                            self.connection = .ready; self.reconnectTask = nil; return
                        } catch SIPError.authFailed {
                            guard self.isCurrentReconnect(gen) else { return }
                            self.connection = .authFailed; self.reconnectTask = nil; return
                        } catch { /* keep retrying */ }
                    }
                } else if await self.reachability.isFritzBoxReachableDirectly() {
                    // Home (the box answers directly) but not over the default route, e.g. through a stale tunnel
                    // of ours: never start a VPN here; stop our own. Re-probe on the next round.
                    guard self.isCurrentReconnect(gen) else { return }
                    if self.startedVPN, !self.callIsLive { await self.stopTunnelAtHome() }
                    guard self.isCurrentReconnect(gen) else { return }
                } else {
                    // The tunnel may have dropped or gone stale (e.g. the FRITZ!Box WAN IP changed while it
                    // reported "connected"): restart our own tunnel, which resolves the endpoint again, or
                    // start one. Then re-probe on the next round.
                    if self.startedVPN { await self.vpn.disconnect() }
                    guard self.isCurrentReconnect(gen) else { return }
                    self.startedVPN = true
                    self.startHomeWatch()
                    do { try await self.vpn.connect(); self.vpnStarted() }
                    catch is CancellationError { /* stopped on purpose */ }
                    catch {
                        guard self.isCurrentReconnect(gen) else { return }
                        let msg = "VPN: \(error.localizedDescription)"
                        self.vpnError = msg; self.lastError = msg
                    }
                }
                delay = min(delay * 2, 60)
            }
        }
    }
    public func waitForReconnect() async { await reconnectTask?.value }

    // MARK: VPN at home

    /// The tunnel came up: the path changed, and any earlier "you are home" notice is stale.
    private func vpnStarted() { pathChanged = true; vpnNotice = nil }

    /// Rebinds the SIP transport once after a path change, before the next registration. During a live call
    /// it stays pending and the re-registration is deferred until the call ends.
    private func applyNetworkChange() {
        guard pathChanged else { return }
        if callIsLive {
            CallLog.logger.info("call #\(self.activeCall?.serial ?? 0, privacy: .public) live: transport rebind deferred until it ends")
            reRegisterAfterCall = true; return
        }
        pathChanged = false
        sip.networkChanged()
    }

    /// Periodic home check while the app's own tunnel is up (cancelled when the tunnel stops or on shutdown).
    private func startHomeWatch() {
        guard homeWatchTask == nil else { return }
        let interval = homeTiming.interval
        homeWatchTask = Task { [weak self, homeSleep] in
            while true {
                await homeSleep(interval)
                guard !Task.isCancelled, let self, self.startedVPN else { return }
                _ = await self.checkHome()
            }
        }
    }

    private func stopHomeWatch() { homeWatchTask?.cancel(); homeWatchTask = nil }

    /// Runs (or joins) one home check. Returns true when it stopped the tunnel (and reconnected without it).
    /// Deferred during a live call; skipped while a connect attempt is in flight (the next tick retries).
    @discardableResult
    private func checkHome() async -> Bool {
        guard startedVPN else { return false }
        if callIsLive {
            if !homeCheckAfterCall { CallLog.logger.info("call #\(self.activeCall?.serial ?? 0, privacy: .public) live: home check deferred until it ends") }
            homeCheckAfterCall = true; return false
        }
        if let t = homeCheckTask { return await t.value }
        guard connectTask == nil else { return false }
        let t = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let home = await self.confirmHome()
            self.homeCheckTask = nil
            guard home, !Task.isCancelled, self.startedVPN else { return false }
            if self.callIsLive { self.homeCheckAfterCall = true; return false }
            await self.stopTunnelAtHome()
            await self.connect(wake: true)   // transport rebind, re-registration, phone book
            return true
        }
        homeCheckTask = t
        return await t.value
    }

    /// `confirmations` successful direct probes in a row, `confirmDelay` apart. One failure ends the check
    /// (flapping while switching networks keeps the tunnel).
    private func confirmHome() async -> Bool {
        for i in 0..<max(1, homeTiming.confirmations) {
            if i > 0 { await homeSleep(homeTiming.confirmDelay) }
            guard !Task.isCancelled, startedVPN, !callIsLive else { return false }
            guard await reachability.isFritzBoxReachableDirectly() else { return false }
        }
        return !Task.isCancelled
    }

    private func stopTunnelAtHome() async {
        stopHomeWatch()
        startedVPN = false
        await vpn.disconnect()
        pathChanged = true
        vpnNotice = Self.homeNotice
        if let v = vpnError, lastError == v { lastError = nil }
        vpnError = nil
        VPNLog.logger.info("Home network reached directly: VPN stopped")
    }

    // MARK: Calls

    public func dial(_ raw: String) {
        guard let number = DialString.dialable(raw) else {
            CallLog.logger.info("dial refused: invalid number"); lastError = "Invalid number"; return
        }
        if let c = activeCall, !isEnded(c) { reconcile(trigger: "dial", runDeferred: true) }
        if let c = activeCall, !isEnded(c) {
            CallLog.logger.info("dial refused: call #\(c.serial, privacy: .public) is live (id \(c.id, privacy: .public), state \(Self.describe(c.state), privacy: .public))")
            lastError = Self.alreadyInCall; return
        }
        guard connection == .ready else {
            CallLog.logger.info("dial refused: not connected"); lastError = "Not connected"; return
        }
        CallLog.logger.info("dial requested")
        do {
            let id = try sip.dial(number)
            beginCall(ActiveCall(id: id, remote: number, displayName: index.name(for: number), isIncoming: false, state: .calling, serial: 0))
        } catch {
            CallLog.logger.error("dial failed in the engine: \(error.localizedDescription, privacy: .public)")
            lastError = "Call failed: \(error.localizedDescription)"
        }
    }
    public func answer() {
        guard let c = activeCall else { CallLog.logger.info("answer requested: no call"); return }
        CallLog.logger.info("call #\(c.serial, privacy: .public) answer requested (id \(c.id, privacy: .public))")
        sip.answer(c.id)
    }
    /// Also declines an unanswered incoming call. Starts the hang-up watchdog.
    public func hangup() {
        guard let c = activeCall else { CallLog.logger.info("hang up requested: no call"); return }
        CallLog.logger.info("call #\(c.serial, privacy: .public) hang up requested (local, id \(c.id, privacy: .public), state \(Self.describe(c.state), privacy: .public))")
        guard !isEnded(c) else { return }
        activeCall?.endedLocally = true
        sip.hangup(c.id)
        startHangupWatch(serial: c.serial)
    }
    public func toggleMute() {
        guard var c = activeCall else { return }
        c.muted.toggle(); activeCall = c; sip.setMuted(c.muted)
    }
    /// Sends keypad digits with the method chosen in Settings and records the outcome on the call.
    /// The digits themselves are never logged, stored or shown (they may be PINs).
    public func sendDTMF(_ digits: String) {
        let clean = digits.filter { Self.dtmfCharacters.contains($0) }
        let method = settings.dtmfMethod
        guard !clean.isEmpty else { DTMFLog.logger.info("DTMF ignored: no sendable digit"); return }
        guard var c = activeCall else {
            DTMFLog.logger.error("DTMF dropped: no active call (count \(clean.count, privacy: .public))"); return
        }
        let outcomes = sip.sendDTMF(clean, callId: c.id, method: method)
        for o in outcomes {
            if let e = o.error {
                DTMFLog.logger.error("DTMF failed: count \(clean.count, privacy: .public), method \(o.method.label, privacy: .public), \(e, privacy: .public)")
            } else {
                DTMFLog.logger.info("DTMF sent: count \(clean.count, privacy: .public), method \(o.method.label, privacy: .public)")
            }
        }
        c.dtmfStatus = Self.dtmfStatus(count: clean.count, outcomes: outcomes)
        c.dtmfSerial += 1
        activeCall = c
    }
    static let dtmfCharacters: Set<Character> = Set("0123456789*#ABCD")

    static func dtmfStatus(count: Int, outcomes: [DTMFOutcome]) -> String {
        let noun = count == 1 ? "Tone" : "\(count) tones"
        guard !outcomes.isEmpty else { return "\(noun) not sent: no result from the engine" }
        return outcomes.map { o in
            o.error.map { "\(noun) failed (\(o.method.label)): \($0)" } ?? "\(noun) sent via \(o.method.label)"
        }.joined(separator: " · ")
    }
    public func clearError() { lastError = nil }
    public func reportError(_ message: String) { lastError = message }

    // MARK: Settings and power

    public func updateSettings(_ s: AppSettings) { settings = s; rebuildIndex(); applyPower() }
    public func powerSourceChanged(onAC: Bool) { self.onAC = onAC; applyPower() }
    private func applyPower() { power.setPreventSleep(onAC && settings.keepAwakeOnPower) }
}

enum VPNLog {
    static let logger = Logger(subsystem: "com.aarneaarebye.sipphone", category: "vpn")
}

enum CallLog {
    /// Call lifecycle; never numbers or names (calls are identified by a serial and the engine id).
    static let logger = Logger(subsystem: "com.aarneaarebye.sipphone", category: "call")
}

enum DTMFLog {
    static let logger = Logger(subsystem: "com.aarneaarebye.sipphone", category: "dtmf")
}
