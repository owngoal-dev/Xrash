import UIKit

/// Links into the other OwnGoal apps. Each is offered only when the app is
/// installed — `canOpenURL` against `LSApplicationQueriesSchemes` — so a menu
/// built from these has nothing to say on a device, or a Mac, without them.
enum SiblingApps {
    /// Fila, with the file selected in its folder.
    static func revealInFila(path: String) -> URL? {
        fila("reveal", [URLQueryItem(name: "path", value: path)])
    }

    /// Fila's viewer on the file.
    static func viewInFila(path: String) -> URL? {
        fila("view", [URLQueryItem(name: "path", value: path)])
    }

    /// Fila, in the app's bundle folder.
    static func appInFila(bundleID: String) -> URL? {
        fila("app", [URLQueryItem(name: "bundle", value: bundleID)])
    }

    /// Irisin's page for an installed package, `com.example.tweak`.
    static func packageInIrisin(identifier: String) -> URL? {
        var components = URLComponents()
        components.scheme = "irisin"
        components.host = "package"
        components.path = "/" + identifier
        return installed(components.url)
    }

    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }

    private static func fila(_ host: String, _ query: [URLQueryItem]) -> URL? {
        var components = URLComponents()
        components.scheme = "fila"
        components.host = host
        components.queryItems = query
        return installed(components.url)
    }

    private static func installed(_ url: URL?) -> URL? {
        guard let url, UIApplication.shared.canOpenURL(url) else { return nil }
        return url
    }
}
