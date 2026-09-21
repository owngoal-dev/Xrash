import Combine
import Foundation
import UIKit
import UserNotifications
import XrashProtocol
import XrashReport

/// A local notification and an icon badge for a report that arrives while the
/// app is running.
///
/// Xrash injects nothing into anything, so there is no notification for a
/// crash that happened while this process was not alive. What it watches is
/// the report directory; what it can honestly say is that a report appeared.
/// One notification per report, and the badge is the unread count the list
/// would show.
@MainActor
final class CrashNotice {
    static let shared = CrashNotice()

    /// The report a notification carries, so a tap can open it.
    static let reportIDKey = "reportID"

    private let library: ReportLibrary
    private let settings: AppSettings
    /// Reports already accounted for. In memory only — see `arrivals`.
    private var accounted = Set<String>()
    /// Everything older than this was already on disk when the app opened.
    private let startedAt = Date()
    private var isAuthorized = false
    private var watches = [DispatchSourceFileSystemObject]()
    private var pendingRefresh: Task<Void, Never>?
    private var observers = Set<AnyCancellable>()

    private init() {
        library = AppEnvironment.shared.library
        // Not a default argument: those are evaluated off the main actor.
        settings = .shared
    }

    // MARK: Which reports are new

    /// The summaries worth a notification: admitted by the filter, written
    /// since the app opened, and not already accounted for.
    ///
    /// The clock is what keeps the first listing quiet. `listAndPublish` lists
    /// through `try?`, so a pass that runs while the daemon is still starting
    /// comes back empty and the next one is the whole directory — "everything
    /// the last listing did not have" would announce all sixty of them.
    nonisolated static func arrivals(
        in summaries: [ReportSummary],
        accounted: Set<String>,
        since start: Date,
        filter: ReportFilter
    ) -> [ReportSummary] {
        summaries.filter { $0.date > start && !accounted.contains($0.id) && filter.admits($0) }
    }

    // MARK: Starting

    func start() {
        #if DEBUG
            assert(Self.arrivalsSelfCheckPassed)
        #endif
        Task { await readAuthorization() }
        library.summaries
            .combineLatest(library.unreadIDs, settings.filter, settings.preferences)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] summaries, unread, filter, _ in
                self?.render(summaries, unread: unread, filter: filter)
            }
            .store(in: &observers)
        watchReportDirectories()
    }

    /// Alert, badge and sound. The OS asks a person once however many times
    /// this is called; the Settings switch asks when it is turned on.
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        isAuthorized = granted
        return granted
    }

    /// A tapped notification. The window knows how to show a report, and it is
    /// found the way `UpdateNotice` finds it.
    func show(reportID: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.first { $0.activationState == .foregroundActive }?
            .windows.first(where: \.isKeyWindow)
            ?? scenes.first?.windows.first(where: \.isKeyWindow)
        (window?.rootViewController as? ReportsSplitViewController)?.showReport(id: reportID)
    }

    /// What a banner should do while the app is in front. The report a person
    /// is already looking at was marked read when it opened, so an unread
    /// report is one they have not seen.
    func presentationOptions(for reportID: String?) -> UNNotificationPresentationOptions {
        guard let reportID, library.unreadIDs.value.contains(reportID) else { return [] }
        return [.banner, .list]
    }

    // MARK: Posting

    private func render(_ summaries: [ReportSummary], unread: Set<String>, filter: ReportFilter) {
        let arrived = Self.arrivals(
            in: summaries,
            accounted: accounted,
            since: startedAt,
            filter: filter
        )
        accounted.formUnion(summaries.map(\.id))
        guard isAuthorized, settings.preferences.value.notifiesOnNewReports else {
            return UnreadBadge.set(0)
        }
        arrived.forEach(post)
        UnreadBadge.set(summaries.filter { unread.contains($0.id) && filter.admits($0) }.count)
    }

    private func post(_ summary: ReportSummary) {
        let content = UNMutableNotificationContent()
        // The process and what happened to it, in the words the list uses.
        content.title = summary.processName
        content.body = ReportFormat.kindLabel(summary.kind)
        content.sound = .default
        content.userInfo = [Self.reportIDKey: summary.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: summary.id, content: content, trigger: nil)
        ) { _ in }
    }

    private func readAuthorization() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        isAuthorized = status == .authorized || status == .provisional
    }

    // MARK: Watching the directory

    /// A report is written while nothing is looking, so without this the list
    /// catches up only on the next foreground. kqueue on the report
    /// directories asks for a refresh instead, debounced: one report is
    /// several writes and each one is an event.
    private func watchReportDirectories() {
        for root in ReportRoots.current() {
            let descriptor = open(root, O_EVTONLY | O_CLOEXEC)
            // The app runs as `mobile`. A directory it cannot open is one the
            // daemon lists on its behalf, and the refresh on becoming active
            // already covers that.
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: .write,
                queue: .main
            )
            source.setEventHandler { [weak self] in self?.scheduleRefresh() }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            watches.append(source)
        }
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task { [weak self] in
            try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
            guard !Task.isCancelled else { return }
            await self?.library.refresh()
        }
    }
}

/// The number on the app icon: the unread reports the list would show. Never
/// cleared by opening the app — it falls as reports are read or deleted.
@MainActor
enum UnreadBadge {
    static func set(_ count: Int) {
        if #available(iOS 16.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(count, withCompletionHandler: nil)
        } else {
            UIApplication.shared.applicationIconBadgeNumber = count
        }
    }
}

#if DEBUG
    extension CrashNotice {
        /// `arrivals` against five reports, once, the first time a debug build
        /// starts it. The failure worth catching in silence is a listing that
        /// announces every report already on the device.
        /// A `static let` runs its closure exactly once.
        static let arrivalsSelfCheckPassed: Bool = {
            let start = Date(timeIntervalSinceReferenceDate: 0)
            func report(_ name: String, secondsFromStart: Int, kind: ReportKind = .crash) -> ReportSummary {
                ReportSummary(
                    id: "/\(name)-\(secondsFromStart).ips",
                    fileName: "\(name)-\(secondsFromStart).ips",
                    processName: name,
                    kind: kind,
                    group: .app,
                    date: start.addingTimeInterval(Double(secondsFromStart)),
                    byteCount: 1,
                    isSynced: false
                )
            }
            let old = report("Fila", secondsFromStart: -60)
            let new = report("Fila", secondsFromStart: 10)
            let known = report("Irisin", secondsFromStart: 20)
            let hidden = report("SpringBoard", secondsFromStart: 30)
            let analytics = report("Siri", secondsFromStart: 40, kind: .analytics)
            var filter = ReportFilter()
            filter.hiddenProcessNames = ["SpringBoard"]
            // `Self` is not allowed in a stored property initializer, even on
            // a final class: name the type.
            let found = CrashNotice.arrivals(
                in: [old, new, known, hidden, analytics],
                accounted: [known.id],
                since: start,
                filter: filter
            )
            assert(found.map(\.id) == [new.id], "only the new, unaccounted, admitted report notifies")
            return true
        }()
    }
#endif
