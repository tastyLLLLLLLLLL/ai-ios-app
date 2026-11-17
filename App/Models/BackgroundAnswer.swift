import BackgroundTasks
import Foundation

/// Experimental: asks iOS 26 to let an answer keep going after the app is minimised.
/// iOS shows the progress on the lock screen and may still stop the task at any time.
@MainActor
final class BackgroundAnswer {
    /// For chat answers.
    static let shared = BackgroundAnswer()
    /// For pictures, video and music being made on the server.
    static let studio = BackgroundAnswer()

    /// True while iOS has granted background time for the current answer.
    private(set) var isRunning = false
    /// Called when iOS takes the background time away.
    var onExpire: (() -> Void)?

    /// The running BGContinuedProcessingTask. Stored untyped because the type only exists on iOS 26.
    private var task: AnyObject?
    private var requestedID: String?

    private init() {}

    /// Background time was asked for or granted and is not finished yet.
    var isActive: Bool { isRunning || requestedID != nil }

    static var isSupported: Bool {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) { return true }
        #endif
        return false
    }

    /// Must be called while the app is open, right when the user starts an answer.
    func begin(title: String, subtitle: String, totalUnits: Int) {
        finish(success: false)
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *) else { return }
        let prefix = Bundle.main.bundleIdentifier ?? "com.personal.pocketai"
        // Registering an identifier that is not listed in Info.plist crashes the app, so check first.
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains("\(prefix).answer.*") else { return }
        let identifier = "\(prefix).answer.\(UUID().uuidString)"
        requestedID = identifier

        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            MainActor.assumeIsolated {
                guard let self, let task = task as? BGContinuedProcessingTask, self.requestedID == identifier else {
                    task.setTaskCompleted(success: false)
                    return
                }
                self.started(task, totalUnits: totalUnits)
            }
        }
        guard registered else { return }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            requestedID = nil
        }
        #endif
    }

    /// Reports how much of the answer is written, so iOS keeps the task alive and shows progress.
    func report(completedUnits: Int) {
        #if compiler(>=6.2)
        guard #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask else { return }
        task.progress.completedUnitCount = min(Int64(completedUnits), task.progress.totalUnitCount)
        #endif
    }

    func finish(success: Bool) {
        requestedID = nil
        isRunning = false
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        #endif
        task = nil
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private func started(_ task: BGContinuedProcessingTask, totalUnits: Int) {
        self.task = task
        isRunning = true
        task.progress.totalUnitCount = Int64(max(1, totalUnits))
        task.progress.completedUnitCount = 0
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.onExpire?()
                self.finish(success: false)
            }
        }
    }
    #endif
}
