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

    public init(sip: SIPEngine, phoneBook: PhoneBookService, vpn: VPNControlling, reachability: Reachability,
                power: PowerAssertionControlling, cache: ContactCache, settings: AppSettings,
                sipConfig: @escaping () -> SIPConfig?,
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }) {
        self.sip = sip; self.phoneBook = phoneBook; self.vpn = vpn; self.reachability = reachability
        self.power = power; self.cache = cache; self.settings = settings; self.sipConfig = sipConfig; self.sleep = sleep
        rebuildIndex()
    }

    // MARK: Lifecycle

    public func start() async { await connect() }
    public func retry() async { await connect() }
    public func handleWake() async { reconnectTask?.cancel(); reconnectTask = nil; await connect() }

    public func shutdown() async {
        eventTask?.cancel(); reconnectTask?.cancel()
        sip.unregister()
        if startedVPN { await vpn.disconnect(); startedVPN = false }
        power.setPreventSleep(false)
    }

    private func connect() async {
        connection = .starting
        if !(await reachability.isFritzBoxReachable()) {
            connection = .connectingVPN
            do { try await vpn.connect(); startedVPN = true }
            catch { connection = .offline("VPN: \(error.localizedDescription)"); return }
            guard await reachability.isFritzBoxReachable() else { connection = .offline("FRITZ!Box not reachable"); return }
        }
        await refreshPhoneBook()
        guard let cfg = sipConfig() else { connection = .offline("Not configured – open Settings"); return }
        connection = .registering
        do { try await sip.register(cfg) }
        catch SIPError.authFailed { connection = .authFailed; return }
        catch { connection = .offline("SIP: \(error)"); return }
        connection = .ready
        startEventLoop()
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
            activeCall = ActiveCall(id: id, remote: remote, displayName: index.name(for: remote), isIncoming: true, state: .ringing)
        case .callState(let id, let state):
            guard activeCall?.id == id else { return }
            activeCall?.state = state
            if case .ended = state { scheduleCallCleanup(id) }
        case .registration(.registered):
            connection = .ready
        case .registration(.failed(let code, _)):
            if code == 401 || code == 403 { connection = .authFailed } else { startReconnect() }
        case .registration(.unregistered):
            break
        }
    }

    private func scheduleCallCleanup(_ id: Int) {
        cleanupTask = Task { [weak self] in
            guard let self else { return }
            await self.sleep(2)
            if self.activeCall?.id == id { self.activeCall = nil }
            await self.refreshHistory()
        }
    }
    public func waitForCallCleanup() async { await cleanupTask?.value }

    private func startReconnect() {
        guard reconnectTask == nil else { return }
        connection = .reconnecting
        reconnectTask = Task { [weak self] in
            var delay = 2.0
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleep(delay)
                if Task.isCancelled { break }
                if await self.reachability.isFritzBoxReachable(), let cfg = self.sipConfig() {
                    do { try await self.sip.register(cfg); self.connection = .ready; break }
                    catch SIPError.authFailed { self.connection = .authFailed; break }
                    catch { /* keep retrying */ }
                }
                delay = min(delay * 2, 60)
            }
            self?.reconnectTask = nil
        }
    }
    public func waitForReconnect() async { await reconnectTask?.value }

    // MARK: Calls

    public func dial(_ number: String) {
        guard activeCall == nil, connection == .ready else { return }
        do {
            let id = try sip.dial(number)
            activeCall = ActiveCall(id: id, remote: number, displayName: index.name(for: number), isIncoming: false, state: .calling)
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
