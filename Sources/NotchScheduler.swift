import Foundation

class NotchScheduler {
    static let shared = NotchScheduler()

    private let storageDir: URL
    private let storageURL: URL
    private var thoughts: [ScheduledThought] = []
    private var timers: [UUID: DispatchSourceTimer] = [:]
    private let queue = DispatchQueue(label: "notch.scheduler", qos: .utility)
    private let lock = NSLock()

    // Caring cycle
    private var caringTimer: DispatchSourceTimer?
    private let caringMinInterval: TimeInterval = 45 * 60
    private let caringMaxInterval: TimeInterval = 90 * 60

    // Coalescing
    private var pendingFired: [ScheduledThought] = []
    private var coalesceTimer: DispatchSourceTimer?

    /// Called when thoughts fire (batched)
    var onThoughtsFired: (([ScheduledThought]) -> Void)?

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        storageDir = home.appendingPathComponent(".notch/scheduler", isDirectory: true)
        storageURL = storageDir.appendingPathComponent("thoughts.json")
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        loadFromDisk()
    }

    // MARK: - Public API

    func schedule(_ thought: ScheduledThought) {
        lock.lock()
        thoughts.append(thought)
        lock.unlock()

        persist()
        scheduleTimer(for: thought)
    }

    func cancel(id: UUID) {
        lock.lock()
        thoughts.removeAll { $0.id == id }
        if let timer = timers.removeValue(forKey: id) {
            timer.cancel()
        }
        lock.unlock()

        persist()
    }

    func allThoughts() -> [ScheduledThought] {
        lock.lock()
        let copy = thoughts
        lock.unlock()
        return copy
    }

    /// Find a thought by full UUID or prefix match
    func findThought(idPrefix: String) -> ScheduledThought? {
        allThoughts().first {
            $0.id.uuidString == idPrefix || $0.id.uuidString.hasPrefix(idPrefix)
        }
    }

    /// Human-readable summary of all scheduled thoughts
    func formattedSummary() -> String {
        let all = allThoughts()
        guard !all.isEmpty else { return "(nothing scheduled)" }

        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short
        return all.map { t in
            "- [\(t.id.uuidString.prefix(8))] \(t.content) | \(df.string(from: t.fireDate)) (\(t.source.rawValue))"
        }.joined(separator: "\n")
    }

    func startCaringCycle() {
        scheduleNextCaringCheck()
    }

    func stopCaringCycle() {
        caringTimer?.cancel()
        caringTimer = nil
    }

    // MARK: - Timer Management

    private func scheduleTimer(for thought: ScheduledThought) {
        let delay = max(0, thought.fireDate.timeIntervalSinceNow)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.thoughtFired(thought)
        }

        lock.lock()
        timers[thought.id] = timer
        lock.unlock()

        timer.resume()
    }

    private func thoughtFired(_ thought: ScheduledThought) {
        // Remove from stored thoughts
        lock.lock()
        thoughts.removeAll { $0.id == thought.id }
        timers.removeValue(forKey: thought.id)

        // If repeating, schedule next occurrence
        if let interval = thought.repeatInterval {
            let nextThought = ScheduledThought(
                content: thought.content,
                source: thought.source,
                fireDate: Date().addingTimeInterval(interval),
                repeatInterval: interval,
                metadata: thought.metadata
            )
            thoughts.append(nextThought)
            lock.unlock()

            persist()
            scheduleTimer(for: nextThought)
        } else {
            lock.unlock()
            persist()
        }

        // Add to coalescing batch
        addToCoalescingBatch(thought)
    }

    private func addToCoalescingBatch(_ thought: ScheduledThought) {
        lock.lock()
        pendingFired.append(thought)

        // Reset coalescing timer
        coalesceTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5)
        timer.setEventHandler { [weak self] in
            self?.flushCoalescingBatch()
        }
        coalesceTimer = timer
        lock.unlock()

        timer.resume()
    }

    private func flushCoalescingBatch() {
        lock.lock()
        let batch = pendingFired
        pendingFired.removeAll()
        coalesceTimer = nil
        lock.unlock()

        guard !batch.isEmpty else { return }
        onThoughtsFired?(batch)
    }

    // MARK: - Caring Cycle

    private func scheduleNextCaringCheck() {
        let interval = TimeInterval.random(in: caringMinInterval...caringMaxInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let heartbeat = NotchCapability.heartbeat
            let thought = ScheduledThought(
                content: "Heartbeat wake. Work through your checklist:\n\(heartbeat)",
                source: .caringCycle,
                fireDate: Date()
            )
            self.addToCoalescingBatch(thought)
            self.scheduleNextCaringCheck()
        }
        timer.resume()
        caringTimer?.cancel()
        caringTimer = timer
    }

    // MARK: - Persistence

    private func persist() {
        lock.lock()
        let toSave = thoughts
        lock.unlock()

        do {
            let data = try JSONEncoder().encode(toSave)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("NotchScheduler: Failed to persist: \(error)")
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let loaded = try? JSONDecoder().decode([ScheduledThought].self, from: data) else {
            return
        }

        let now = Date()
        for thought in loaded {
            if thought.fireDate > now {
                // Future thought — reschedule
                thoughts.append(thought)
                scheduleTimer(for: thought)
            }
            // Past thoughts are discarded
        }
    }
}
