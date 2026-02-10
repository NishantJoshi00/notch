import Foundation
import Virtualization

/// Manages side-quest VMs — spawning, tracking, harvesting results, killing.
/// Each quest runs in an isolated Linux VM via Virtualization.framework.
class QuestManager {
    static let shared = QuestManager()

    private let baseDir: URL
    private let vmDir: URL
    private let activeDir: URL
    private let resultsDir: URL
    private let sharedBase: URL

    private var activeVM: ActiveQuest?
    private let lock = NSLock()

    struct QuestInfo: Codable {
        let id: String
        let goal: String
        let model: String
        let maxTurns: Int
        let maxBudgetUSD: Double
        let timeoutSeconds: Int
        let startedAt: Date
    }

    private class ActiveQuest {
        let info: QuestInfo
        let vm: VZVirtualMachine
        let sharedDir: URL
        var timeoutTimer: DispatchSourceTimer?

        init(info: QuestInfo, vm: VZVirtualMachine, sharedDir: URL) {
            self.info = info
            self.vm = vm
            self.sharedDir = sharedDir
        }
    }

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        baseDir = home.appendingPathComponent(".notch/quests", isDirectory: true)
        vmDir = baseDir.appendingPathComponent("vm", isDirectory: true)
        activeDir = baseDir.appendingPathComponent("active", isDirectory: true)
        resultsDir = baseDir.appendingPathComponent("results", isDirectory: true)
        sharedBase = baseDir.appendingPathComponent("shared", isDirectory: true)

        for dir in [baseDir, vmDir, activeDir, resultsDir, sharedBase] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // Clean up any stale active files from previous runs
        cleanupStaleActive()
    }

    // MARK: - Public API

    /// Whether the VM image is available (user ran build-quest-vm.sh)
    var isVMReady: Bool {
        let kernel = vmDir.appendingPathComponent("vmlinux")
        let rootfs = vmDir.appendingPathComponent("rootfs.ext4")
        return FileManager.default.fileExists(atPath: kernel.path)
            && FileManager.default.fileExists(atPath: rootfs.path)
    }

    /// Spawn a new quest VM. Returns quest ID or error.
    func spawn(goal: String, apiKey: String, model: String = "claude-opus-4-6",
               maxTurns: Int = 20, maxBudgetUSD: Double = 0.50,
               timeoutMinutes: Int = 5) -> Result<String, QuestError> {

        lock.lock()
        let hasActive = activeVM != nil
        lock.unlock()

        if hasActive {
            return .failure(.alreadyRunning)
        }

        guard isVMReady else {
            return .failure(.vmNotBuilt)
        }

        let questId = UUID().uuidString.prefix(8).lowercased()
        let info = QuestInfo(
            id: String(questId),
            goal: goal,
            model: model,
            maxTurns: maxTurns,
            maxBudgetUSD: maxBudgetUSD,
            timeoutSeconds: timeoutMinutes * 60,
            startedAt: Date()
        )

        // Create shared directory for this quest
        let sharedDir = sharedBase.appendingPathComponent(info.id, isDirectory: true)
        try? FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)

        // Write goal file
        let goalData: [String: Any] = [
            "goal": goal,
            "model": model,
            "max_turns": maxTurns,
            "max_budget_usd": maxBudgetUSD,
            "api_key": apiKey
        ]
        if let data = try? JSONSerialization.data(withJSONObject: goalData) {
            try? data.write(to: sharedDir.appendingPathComponent("goal.json"))
        }

        // Save tracking file
        if let trackData = try? JSONEncoder().encode(info) {
            try? trackData.write(to: activeDir.appendingPathComponent("\(info.id).json"))
        }

        // Boot the VM
        do {
            let vm = try createVM(sharedDir: sharedDir)
            let quest = ActiveQuest(info: info, vm: vm, sharedDir: sharedDir)

            // Start timeout timer
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .seconds(info.timeoutSeconds))
            timer.setEventHandler { [weak self] in
                self?.cancel(id: info.id)
            }
            timer.resume()
            quest.timeoutTimer = timer

            lock.lock()
            activeVM = quest
            lock.unlock()

            // Start VM on main thread (VZVirtualMachine requirement)
            DispatchQueue.main.async {
                vm.start { result in
                    if case .failure(let error) = result {
                        print("QuestManager: VM start failed: \(error)")
                        self.handleQuestFinished(id: info.id, error: error.localizedDescription)
                    }
                }
            }

            // Monitor VM state for completion
            monitorVM(quest: quest)

            return .success(info.id)
        } catch {
            // Cleanup on failure
            try? FileManager.default.removeItem(at: sharedDir)
            try? FileManager.default.removeItem(at: activeDir.appendingPathComponent("\(info.id).json"))
            return .failure(.vmCreateFailed(error.localizedDescription))
        }
    }

    /// List active quests
    func list() -> [QuestInfo] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil) else {
            return []
        }
        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(QuestInfo.self, from: data)
        }
    }

    /// Check for completed quest results. Returns [(id, goal, result)] and cleans up.
    func harvest() -> [(id: String, goal: String, result: String)] {
        var completed: [(id: String, goal: String, result: String)] = []

        guard let resultFiles = try? FileManager.default.contentsOfDirectory(at: resultsDir, includingPropertiesForKeys: nil) else {
            return completed
        }

        for resultFile in resultFiles {
            guard resultFile.pathExtension == "md" else { continue }
            let questId = resultFile.deletingPathExtension().lastPathComponent

            if let result = try? String(contentsOf: resultFile, encoding: .utf8) {
                // Try to read the original goal from active tracking
                var goal = "(unknown goal)"
                let trackFile = activeDir.appendingPathComponent("\(questId).json")
                if let data = try? Data(contentsOf: trackFile),
                   let info = try? JSONDecoder().decode(QuestInfo.self, from: data) {
                    goal = info.goal
                }

                completed.append((id: questId, goal: goal, result: result))

                // Cleanup
                try? FileManager.default.removeItem(at: resultFile)
                try? FileManager.default.removeItem(at: trackFile)
                try? FileManager.default.removeItem(at: sharedBase.appendingPathComponent(questId))
            }
        }

        return completed
    }

    /// Cancel a running quest
    func cancel(id: String) {
        lock.lock()
        guard let quest = activeVM, quest.info.id == id else {
            lock.unlock()
            return
        }
        lock.unlock()

        handleQuestFinished(id: id, error: "Cancelled")
    }

    /// Kill all running quests (called on app quit)
    func killAll() {
        lock.lock()
        guard let quest = activeVM else {
            lock.unlock()
            return
        }
        lock.unlock()

        quest.timeoutTimer?.cancel()
        DispatchQueue.main.async {
            try? quest.vm.requestStop()
        }

        lock.lock()
        activeVM = nil
        lock.unlock()
    }

    // MARK: - VM Creation

    private func createVM(sharedDir: URL) throws -> VZVirtualMachine {
        let kernelURL = vmDir.appendingPathComponent("vmlinux")
        let rootfsURL = vmDir.appendingPathComponent("rootfs.ext4")

        // Boot loader
        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw init=/quest/boot.sh"

        // Root disk (read-only base image — each quest gets a fresh view)
        let rootAttachment = try VZDiskImageStorageDeviceAttachment(url: rootfsURL, readOnly: false)
        let rootDisk = VZVirtioBlockDeviceConfiguration(attachment: rootAttachment)

        // Shared directory for quest I/O
        let sharedDevice = VZVirtioFileSystemDeviceConfiguration(tag: "shared")
        sharedDevice.share = VZSingleDirectoryShare(
            directory: VZSharedDirectory(url: sharedDir, readOnly: false)
        )

        // Serial console (capture output for debugging)
        let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
        let pipe = Pipe()
        serial.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: FileHandle.nullDevice,
            fileHandleForWriting: pipe.fileHandleForWriting
        )

        // Network (for web search)
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        // Entropy
        let entropy = VZVirtioEntropyDeviceConfiguration()

        // Configuration
        let config = VZVirtualMachineConfiguration()
        config.bootLoader = bootLoader
        config.cpuCount = 2
        config.memorySize = 1 * 1024 * 1024 * 1024  // 1GB
        config.serialPorts = [serial]
        config.storageDevices = [rootDisk]
        config.directorySharingDevices = [sharedDevice]
        config.networkDevices = [networkDevice]
        config.entropyDevices = [entropy]

        try config.validate()

        // VZVirtualMachine must be created on main thread
        var vm: VZVirtualMachine!
        if Thread.isMainThread {
            vm = VZVirtualMachine(configuration: config)
        } else {
            DispatchQueue.main.sync {
                vm = VZVirtualMachine(configuration: config)
            }
        }

        return vm
    }

    // MARK: - VM Monitoring

    private func monitorVM(quest: ActiveQuest) {
        // Poll VM state until it stops
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                timer.cancel()
                return
            }

            var state: VZVirtualMachine.State = .stopped
            DispatchQueue.main.sync {
                state = quest.vm.state
            }

            if state == .stopped || state == .error {
                timer.cancel()
                self.handleQuestCompleted(quest: quest)
            }
        }
        timer.resume()
    }

    private func handleQuestCompleted(quest: ActiveQuest) {
        let resultFile = quest.sharedDir.appendingPathComponent("result.md")
        let destFile = resultsDir.appendingPathComponent("\(quest.info.id).md")

        if FileManager.default.fileExists(atPath: resultFile.path) {
            try? FileManager.default.moveItem(at: resultFile, to: destFile)
        } else {
            // Check for stderr
            let stderrFile = quest.sharedDir.appendingPathComponent("stderr.log")
            let stderr = (try? String(contentsOf: stderrFile, encoding: .utf8)) ?? ""
            let errorMsg = "Quest completed but no result file.\(stderr.isEmpty ? "" : "\nStderr: \(stderr)")"
            try? errorMsg.write(to: destFile, atomically: true, encoding: .utf8)
        }

        quest.timeoutTimer?.cancel()

        lock.lock()
        if activeVM?.info.id == quest.info.id {
            activeVM = nil
        }
        lock.unlock()
    }

    private func handleQuestFinished(id: String, error: String) {
        lock.lock()
        guard let quest = activeVM, quest.info.id == id else {
            lock.unlock()
            return
        }
        lock.unlock()

        // Write error as result
        let destFile = resultsDir.appendingPathComponent("\(id).md")
        try? "Quest ended: \(error)".write(to: destFile, atomically: true, encoding: .utf8)

        // Stop VM
        quest.timeoutTimer?.cancel()
        DispatchQueue.main.async {
            try? quest.vm.requestStop()
        }

        lock.lock()
        activeVM = nil
        lock.unlock()
    }

    private func cleanupStaleActive() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: activeDir, includingPropertiesForKeys: nil) else { return }
        for file in files {
            // Move stale active to results as "interrupted"
            let id = file.deletingPathExtension().lastPathComponent
            let resultFile = resultsDir.appendingPathComponent("\(id).md")
            if !FileManager.default.fileExists(atPath: resultFile.path) {
                try? "Quest interrupted (app restarted)".write(to: resultFile, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Errors

    enum QuestError: Error, CustomStringConvertible {
        case alreadyRunning
        case vmNotBuilt
        case vmCreateFailed(String)

        var description: String {
            switch self {
            case .alreadyRunning: return "A quest is already running. One at a time."
            case .vmNotBuilt: return "Quest VM not built yet. Run: scripts/build-quest-vm.sh"
            case .vmCreateFailed(let msg): return "Failed to create VM: \(msg)"
            }
        }
    }
}
