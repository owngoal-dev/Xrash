import Foundation

public extension Report {
    /// `EXC_CRASH (SIGABRT)`, or the termination reason when there is no
    /// exception. Nil for a report whose kind says everything already. The
    /// list row and the notification both say this, so it is decided once.
    var reason: String? {
        if let exception = crash?.exception {
            return exception.typeAndSignal
        }
        if let termination = crash?.termination {
            let namespace = termination.namespace.map { "\($0)" }
            return [namespace, termination.indicator].compactMap(\.self).first
        }
        if let panic {
            return panic.panicString.split(separator: "\n").first.map(String.init)
        }
        return nil
    }
}
