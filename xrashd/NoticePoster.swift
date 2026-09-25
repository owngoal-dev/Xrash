import Foundation
import XrashNotice
import XrashProtocol
import XrashReport

#if os(macOS)

    /// The Mac's helper is a per-user agent signed with no entitlement, so it
    /// cannot post for the app, and the app there announces on its own.
    struct NoticePoster {
        init?() {
            nil
        }

        func post(_: Notice, detail _: NoticeDetail?, completion: @escaping () -> Void) {
            completion()
        }
    }

#else

    import ObjectiveC
    import UserNotifications

    /// Posts as the app. `usernotificationsd` admits a center made for another
    /// bundle only from a process whose
    /// `com.apple.private.usernotifications.bundle-identifiers` names it; the
    /// notification then is the app's in every way — its icon, its settings,
    /// its authorization, and a tap opens it.
    struct NoticePoster {
        /// The key the app reads a tapped notification's report from:
        /// `CrashNotice.reportIDKey`.
        private static let reportIDKey = "reportID"

        private let center: UNUserNotificationCenter

        /// Nil when the OS no longer has the initializer, which is asked
        /// rather than assumed: it is not in the SDK.
        init?() {
            let selector = NSSelectorFromString("initWithBundleIdentifier:")
            guard let method = class_getInstanceMethod(UNUserNotificationCenter.self, selector),
                  let allocated = (UNUserNotificationCenter.self as AnyObject)
                  .perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
            else { return nil }
            typealias Initializer = @convention(c) (AnyObject, Selector, NSString) -> Unmanaged<AnyObject>?
            let initialize = unsafeBitCast(method_getImplementation(method), to: Initializer.self)
            let made = initialize(allocated, selector, XrashService.appBundleIdentifier as NSString)
            guard let center = made?.takeUnretainedValue() as? UNUserNotificationCenter else { return nil }
            self.center = center
        }

        func post(_ notice: Notice, detail: NoticeDetail?, completion: @escaping () -> Void) {
            let content = UNMutableNotificationContent()
            // Two lines: who and what, then why — `Fila Crashed` over the list
            // row's `EXC_CRASH (SIGABRT) · 0.2.0 (43)`. Keys are resolved by
            // the system against the app's own catalogue, in the language the
            // app would have used.
            let name = detail?.processName ?? notice.processName
            if notice.kind == .crash {
                content.title = NSString.localizedUserNotificationString(
                    forKey: Self.crashedTitleKey,
                    arguments: [name],
                )
                content.body = detail?.line ?? ""
            } else {
                // A `JetsamEvent` did not crash; its kind is the second line
                // unless the report had something more exact to say.
                content.title = name
                content.body = detail?.line
                    ?? NSString.localizedUserNotificationString(forKey: Self.bodyKey(notice.kind), arguments: nil)
            }
            // One stack per binary: a crash loop is one pile, not a wall.
            content.threadIdentifier = name
            content.sound = .default
            content.badge = NSNumber(value: notice.badge)
            content.userInfo = [Self.reportIDKey: notice.path]
            // The report's path, as the app uses: one that both sides saw is
            // one notification.
            center.add(UNNotificationRequest(identifier: notice.path, content: content, trigger: nil)) { _ in
                completion()
            }
        }

        /// The key `CrashNotice.post` spells in the app, for the same reason.
        private static let crashedTitleKey = "%@ Crashed"

        /// The keys of `ReportFormat.kindLabel` in the app, which is where the
        /// compiler extracts them from. Keep the two spelled alike.
        private static func bodyKey(_ kind: ReportKind) -> String {
            switch kind {
            case .crash: "Crash"
            case .jetsam: "Out of Memory"
            case .panic: "Kernel Panic"
            case .hang: "Hang"
            case .resource: "Resource Limit"
            case .analytics: "Analytics"
            case .other: "Log"
            }
        }
    }

#endif
