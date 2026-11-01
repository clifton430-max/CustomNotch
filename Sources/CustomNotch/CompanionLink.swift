import AppKit
import Combine
import ImageIO

/// The Terraria Companion app's local link (its `notch_link.rs`): who lives in the notch, what she
/// says, and the user's actions on her. One long-poll is kept open, so news arrives immediately and
/// an idle link costs nothing; it doubles as the heartbeat both sides use to notice the other leaving.
@MainActor
final class CompanionLink: ObservableObject {
    struct Box: Decodable, Equatable { let x, y, w, h: Double }

    struct Colors: Codable, Equatable {
        let top, bottom, border, text, heart: String
    }

    struct Resident: Decodable, Equatable {
        let character: String
        let name: String
        let atlas: String
        let frameWidth: Int
        let frameHeight: Int
        let frames: [String]
        let body: Box
        let bubble: Colors
        let gestures: [String]
        let stride: Double
        /// Her draw scale on the desktop, points per art pixel.
        let scale: Double
        let arrival: Int
        let arrivalFresh: Bool
    }

    private struct State: Decodable {
        struct Message: Decodable { let id: Int; let character, name, text: String; let at: Double }
        struct Gesture: Decodable { let id: Int; let kind: String }
        let session: Int
        let version: Int
        let resident: Resident?
        let messages: [Message]
        let gesture: Gesture?
        let hover: String
    }

    /// Something she said, kept until it's been read (and a while after, to look back on).
    struct Message: Codable, Identifiable, Equatable {
        let id: String
        let character: String
        let name: String
        let text: String
        let date: Date
        let colors: Colors?
        var read: Bool
    }

    @Published private(set) var connected = false
    @Published private(set) var resident: Resident?
    @Published private(set) var atlas: CompanionAtlas?
    /// A companion held over the notch: "empty" (it'll take her), "full", "incoming" (on her way in).
    @Published private(set) var hover = ""
    @Published private(set) var messages: [Message] = []
    /// She said something while the notch was closed; stays on until the notch is opened.
    @Published private(set) var glowing = false

    /// Expressions and gestures she plays (wave, hug, sit, happy, hearts…).
    let gestures = PassthroughSubject<String, Never>()
    /// A companion just moved in (play the gulp and her landing).
    let arrivals = PassthroughSubject<Void, Never>()

    /// Set by the controller while the notch is open, so new lines show right away.
    var isOpen = false {
        didSet { if isOpen { glowing = false; saveMessages() } }
    }

    var unread: [Message] { messages.filter { !$0.read } }

    private let base = URL(string: "http://127.0.0.1:47834")!
    private let session: URLSession
    private var pollTask: Task<Void, Never>?
    private var serverSession = 0
    private var version = 0
    private var lastGesture = -1
    /// Seen this run's state once (its old gesture isn't replayed).
    private var primed = false
    private var lastArrival = -1
    private var failures = 0
    private var pendingGeometry: [String: Any]?
    private var postedGeometry: [String: Any]?
    private var geometryInFlight = false

    private static let messagesKey = "companionMessages"
    private static let glowKey = "companionGlowing"
    private static let seenKey = "companionSeen"
    private static let keep = 60

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.messagesKey),
           let stored = try? JSONDecoder().decode([Message].self, from: data) {
            messages = stored
        }
        glowing = d.bool(forKey: Self.glowKey) && !unread.isEmpty
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
            }
        }
    }

    // MARK: Polling

    private func request(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: path, relativeTo: base)!)
        r.httpMethod = method
        r.setValue("1", forHTTPHeaderField: "X-Notch-Link")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    private func pollOnce() async {
        let path = serverSession == 0 ? "/notch/state" : "/notch/state?session=\(serverSession)&since=\(version)"
        do {
            let (data, response) = try await session.data(for: request(path))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let state = try JSONDecoder().decode(State.self, from: data)
            failures = 0
            if !connected {
                connected = true
                postedGeometry = nil // the companion app may be new: tell it where we are
                flushGeometry()
            }
            await apply(state)
        } catch {
            failures += 1
            if failures >= 2, connected || resident != nil { disconnect() }
            try? await Task.sleep(for: .seconds(failures > 3 ? 3 : 1))
        }
    }

    private func disconnect() {
        connected = false
        serverSession = 0
        version = 0
        hover = ""
        if resident != nil {
            resident = nil
            atlas = nil
        }
    }

    private func apply(_ s: State) async {
        if s.session != serverSession {
            // A new run of the companion app: its counters start over.
            lastGesture = -1
            lastArrival = -1
            primed = false
        }
        serverSession = s.session
        version = s.version
        if hover != s.hover { hover = s.hover }

        if let r = s.resident {
            if atlas?.path != r.atlas, let image = await loadAtlas(r.atlas) {
                atlas = CompanionAtlas(path: r.atlas, image: image, resident: r)
            }
            if resident != r { resident = r }
            if r.arrival != lastArrival {
                lastArrival = r.arrival
                if r.arrivalFresh { arrivals.send() }
            }
        } else if resident != nil {
            resident = nil
            atlas = nil
        }

        if let g = s.gesture {
            // (The first look at the state doesn't replay an old gesture.)
            if primed, g.id != lastGesture { gestures.send(g.kind) }
            lastGesture = g.id
        }
        primed = true
        ingest(s.messages, session: s.session)
    }

    private func loadAtlas(_ path: String) async -> CGImage? {
        guard let (data, response) = try? await session.data(for: request(path)),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    // MARK: Messages

    /// New lines from her (each kept; nothing overwrites another). Ids are per companion-app run.
    private func ingest(_ incoming: [State.Message], session: Int) {
        let d = UserDefaults.standard
        let seen = d.dictionary(forKey: Self.seenKey) as? [String: Int] ?? [:]
        let last = seen[String(session)] ?? 0
        let fresh = incoming.filter { $0.id > last }
        guard let newest = fresh.map(\.id).max() else { return }
        // Only this run's high-water mark matters; older runs can't send more.
        d.set([String(session): newest], forKey: Self.seenKey)
        let colors = resident?.bubble
        for m in fresh {
            messages.append(Message(id: "\(session)-\(m.id)", character: m.character, name: m.name, text: m.text,
                                    date: Date(timeIntervalSince1970: m.at / 1000), colors: colors, read: false))
        }
        trim()
        if !isOpen { glowing = true }
        saveMessages()
    }

    /// Keep every unread line; drop the oldest read ones past the limit.
    private func trim() {
        var extra = messages.count - Self.keep
        guard extra > 0 else { return }
        messages.removeAll { m in
            guard extra > 0, m.read else { return false }
            extra -= 1
            return true
        }
    }

    func markRead(_ id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }), !messages[i].read else { return }
        messages[i].read = true
        saveMessages()
    }

    func clearHistory() {
        messages.removeAll { $0.read }
        saveMessages()
    }

    private func saveMessages() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(messages) { d.set(data, forKey: Self.messagesKey) }
        d.set(glowing, forKey: Self.glowKey)
    }

    // MARK: Outgoing

    /// Where the notch is (global points, top-left origin). Coalesced; only changes are sent.
    func postGeometry(_ rect: CGRect, edge: NotchEdge, expanded: Bool, dragging: Bool) {
        pendingGeometry = [
            "x": rect.minX.rounded(), "y": rect.minY.rounded(), "w": rect.width.rounded(), "h": rect.height.rounded(),
            "edge": edge.rawValue, "expanded": expanded, "dragging": dragging,
        ]
        flushGeometry()
    }

    private func flushGeometry() {
        guard connected, !geometryInFlight, let g = pendingGeometry else { return }
        if let posted = postedGeometry, NSDictionary(dictionary: posted).isEqual(to: g) { return }
        guard let body = try? JSONSerialization.data(withJSONObject: g) else { return }
        geometryInFlight = true
        Task {
            let ok = (try? await session.data(for: request("/notch/geometry", method: "POST", body: body)))
                .map { ($0.1 as? HTTPURLResponse)?.statusCode == 204 } ?? false
            geometryInFlight = false
            if ok { postedGeometry = g }
            // Anything newer that arrived meanwhile.
            if ok, let p = pendingGeometry, !NSDictionary(dictionary: p).isEqual(to: g) { flushGeometry() }
        }
    }

    /// "exit" (at a global top-left point, moving at vx/vy points per second), "pet" or "inventory".
    @discardableResult
    func send(_ kind: String, at point: CGPoint = .zero, velocity: CGVector = .zero) async -> Bool {
        let payload: [String: Any] = ["kind": kind, "x": point.x, "y": point.y, "vx": velocity.dx, "vy": velocity.dy]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let (_, response) = try? await session.data(for: request("/notch/action", method: "POST", body: body))
        else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 204
    }
}

/// A resident's sprite sheet: one row of cells, cut into frames on demand.
@MainActor
final class CompanionAtlas {
    let path: String
    let image: CGImage
    let resident: CompanionLink.Resident
    private var cache: [String: CGImage] = [:]
    let walkFrames: Int

    init(path: String, image: CGImage, resident: CompanionLink.Resident) {
        self.path = path
        self.image = image
        self.resident = resident
        walkFrames = resident.frames.filter { $0.hasPrefix("walk") && Int($0.dropFirst(4)) != nil }.count
    }

    /// The requested pose, or the closest one the sheet has (mirrors the overlay's `resolveFrame`).
    func resolve(_ name: String) -> String {
        let frames = resident.frames
        if frames.contains(name) { return name }
        var chain: [String] = []
        switch name {
        case "sit", "ride", "nap": chain = ["sit", "jump", "fall"]
        case "happy", "shy": chain = ["wave1", "cast"]
        case "glide": chain = ["jump", "fall"]
        default:
            if name.hasPrefix("wave") || name == "hug" { chain = ["cast", "shoot"] }
            else if name.hasPrefix("walk") { chain = ["walk0"] }
            else if name.hasPrefix("use") { chain = ["use1", "shoot"] }
        }
        chain.append("idle")
        return chain.first(where: frames.contains) ?? frames.first ?? name
    }

    func frame(_ name: String) -> CGImage? {
        let resolved = resolve(name)
        if let hit = cache[resolved] { return hit }
        guard let i = resident.frames.firstIndex(of: resolved) else { return nil }
        let fw = resident.frameWidth, fh = resident.frameHeight
        guard let cell = image.cropping(to: CGRect(x: i * fw, y: 0, width: fw, height: fh)) else { return nil }
        cache[resolved] = cell
        return cell
    }
}
