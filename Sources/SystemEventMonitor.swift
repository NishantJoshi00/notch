import Cocoa

class SystemEventMonitor {
    private var lastActivityDate: Date?
    private let idleThreshold: TimeInterval = 30 * 60  // 30 minutes
    private var hasGreetedToday = false
    private var lastGreetingDate: Date?
    private var idleCheckTimer: Timer?

    /// Called when a system event produces a thought to process
    var onSystemEvent: ((ScheduledThought) -> Void)?

    func start() {
        // Laptop wake from sleep
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleWake),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )

        // Screen unlock (proxy for "user is back")
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(handleScreenUnlock),
            name: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil
        )

        lastActivityDate = Date()

        // Periodic idle check + daily greeting reset (every 5 min)
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.periodicCheck()
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        idleCheckTimer?.invalidate()
        idleCheckTimer = nil
    }

    /// Called whenever the user interacts with Notch
    func recordActivity() {
        let wasIdle = isIdle()
        lastActivityDate = Date()

        if wasIdle {
            let thought = ScheduledThought(
                content: "User returned after being idle for a while. They might appreciate a 'welcome back' if appropriate.",
                source: .systemEvent,
                fireDate: Date(),
                metadata: ["event": "idle_resume"]
            )
            onSystemEvent?(thought)
        }
    }

    private func isIdle() -> Bool {
        guard let last = lastActivityDate else { return false }
        return Date().timeIntervalSince(last) > idleThreshold
    }

    @objc private func handleWake() {
        let hour = Calendar.current.component(.hour, from: Date())

        // Morning: first wake between 5am-11am
        if hour >= 5 && hour < 12 && !hasGreetedToday {
            if let lastGreeting = lastGreetingDate, Calendar.current.isDateInToday(lastGreeting) {
                return
            }
            hasGreetedToday = true
            lastGreetingDate = Date()

            let thought = ScheduledThought(
                content: "First activity of the day. Good morning greeting might be appropriate. Consider mentioning weather or something warm.",
                source: .systemEvent,
                fireDate: Date(),
                metadata: ["event": "morning_first_activity"]
            )
            onSystemEvent?(thought)
        } else if hour >= 0 && hour < 5 {
            // Late night — existential question territory
            let thought = ScheduledThought(
                content: "User opened laptop very late at night. A fun existential question or a gentle 'you're up late' might land well.",
                source: .systemEvent,
                fireDate: Date(),
                metadata: ["event": "late_night_wake"]
            )
            onSystemEvent?(thought)
        } else {
            let thought = ScheduledThought(
                content: "Laptop woke from sleep.",
                source: .systemEvent,
                fireDate: Date(),
                metadata: ["event": "laptop_wake"]
            )
            onSystemEvent?(thought)
        }
    }

    @objc private func handleScreenUnlock() {
        recordActivity()
    }

    private func periodicCheck() {
        // Reset daily greeting flag at midnight
        if let lastGreeting = lastGreetingDate, !Calendar.current.isDateInToday(lastGreeting) {
            hasGreetedToday = false
        }
    }
}
