import Foundation
import Observation
import UIKit

/** A published release of Kinema. */
struct AppRelease: Codable, Hashable, Identifiable {
    var id: String { version }
    var version: String
    var title: String
    /** The release notes, in Markdown. */
    var notes: String
    var publishedAt: String?
    var pageUrl: String
    var ipaUrl: String?
}

enum UpdateCheck: Equatable {
    case idle, checking
    case upToDate(String)
    case available(AppRelease)
    case failed(String)
}

/**
 * Finds out whether a newer Kinema has been released.
 *
 * Releases are this repository's GitHub releases. Kinema looks at most twice
 * a day by itself, when it comes to the front (and whenever asked in
 * Settings → About); a newer one shows as a banner until it is dismissed.
 * Kinema cannot install itself, so updating hands the new IPA to SideStore or
 * AltStore when one of them is on the phone, or opens the release page.
 */
@MainActor
@Observable
final class UpdateChecker {
    static let repository = "evropiani/Kinema"

    private(set) var check: UpdateCheck = .idle
    /** The newest release, if it is newer than this app. Kept between launches. */
    private(set) var available: AppRelease?
    /** The version whose banner was dismissed. */
    private(set) var dismissed: String?

    private static let availableKey = "updates.available"
    private static let dismissedKey = "updates.dismissed"
    private static let checkedAtKey = "updates.checkedAt"
    private static let interval: TimeInterval = 12 * 3600

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: Self.availableKey),
           let release = try? JSONDecoder().decode(AppRelease.self, from: data),
           Versions.isNewer(release.version, than: appVersion) {
            available = release
        }
        dismissed = defaults.string(forKey: Self.dismissedKey)
    }

    /** Look by itself, if it has not looked in the last twelve hours. */
    func checkInBackground() {
        #if DEBUG
        // Builds made for development (and CI's screenshots) do not nag.
        return
        #else
        let last = UserDefaults.standard.double(forKey: Self.checkedAtKey)
        guard Date().timeIntervalSince1970 - last >= Self.interval else { return }
        Task { _ = await checkNow() }
        #endif
    }

    /** Ask GitHub for the latest release now. */
    @discardableResult
    func checkNow() async -> UpdateCheck {
        check = .checking
        do {
            let latest = try await Self.fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.checkedAtKey)
            if Versions.isNewer(latest.version, than: appVersion) {
                available = latest
                if let data = try? JSONEncoder().encode(latest) { UserDefaults.standard.set(data, forKey: Self.availableKey) }
                check = .available(latest)
            } else {
                available = nil
                UserDefaults.standard.removeObject(forKey: Self.availableKey)
                check = .upToDate(latest.version)
            }
        } catch {
            check = .failed(JellyfinError.from(error).localizedDescription)
        }
        return check
    }

    func dismiss(_ release: AppRelease) {
        dismissed = release.version
        UserDefaults.standard.set(release.version, forKey: Self.dismissedKey)
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let name: String?
        let body: String?
        let published_at: String?
        let html_url: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]?
    }

    private static func fetchLatest() async throws -> AppRelease {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else { throw URLError(.badURL) }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kinema-iOS/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw JellyfinError.network("GitHub answered with HTTP \(http.statusCode).")
        }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        let version = Versions.fromTag(release.tag_name)
        return AppRelease(
            version: version,
            title: release.name ?? "Kinema \(version)",
            notes: release.body ?? "",
            publishedAt: release.published_at,
            pageUrl: release.html_url,
            ipaUrl: release.assets?.first { $0.name.lowercased().hasSuffix(".ipa") }?.browser_download_url
        )
    }

    // ------------------------------------------------------------ updating --

    /** The sideloading apps that can install the new IPA themselves, and how to ask them. */
    enum Installer: CaseIterable {
        case sideStore, altStore

        var name: String { self == .sideStore ? "SideStore" : "AltStore" }

        func link(for ipa: String) -> URL? {
            guard let encoded = ipa.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
            return URL(string: "\(self == .sideStore ? "sidestore" : "altstore")://install?url=\(encoded)")
        }

        @MainActor
        var installed: Bool {
            URL(string: self == .sideStore ? "sidestore://" : "altstore://").map { UIApplication.shared.canOpenURL($0) } ?? false
        }
    }
}
