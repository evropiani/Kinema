import Foundation
import Observation
import UIKit

/** One signed-in account: a user on a server. */
struct ServerProfile: Codable, Hashable, Identifiable {
    var id: String
    var serverId: String
    var serverName: String
    var serverUrl: String
    var userId: String
    var username: String
    var userImageTag: String?
    var addedAt: Date

    var url: URL? { URL(string: serverUrl) }
    var host: String { url?.host ?? serverUrl }
}

/**
 * The servers and users this phone is signed in to, which one is in use, and
 * a client for it. Tokens are kept in the Keychain; the list itself in
 * UserDefaults.
 */
@MainActor
@Observable
final class AuthRepository {
    private static let profilesKey = "auth.profiles"
    private static let activeKey = "auth.active"
    private static let deviceKey = "auth.deviceId"

    private(set) var profiles: [ServerProfile] = []
    private(set) var activeId: String?
    private(set) var client: JellyfinClient?
    /** The signed-in user as the server last described them (preferences, permissions). */
    private(set) var user: UserDto?
    /** The server's version, from its public information. */
    private(set) var serverVersion: String?
    /** Bumped whenever the account in use changes, so pages reload. */
    private(set) var generation = 0

    @ObservationIgnored let info: ClientInfo
    @ObservationIgnored private var listeners: [(ServerProfile?) -> Void] = []

    init() {
        let defaults = UserDefaults.standard
        var deviceId = defaults.string(forKey: Self.deviceKey) ?? ""
        if deviceId.isEmpty {
            deviceId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            defaults.set(deviceId, forKey: Self.deviceKey)
        }
        info = ClientInfo(name: "Kinema", version: appVersion, deviceName: UIDevice.current.name, deviceId: deviceId)
        if let data = defaults.data(forKey: Self.profilesKey), let stored = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = stored
        }
        activeId = defaults.string(forKey: Self.activeKey)
        if active == nil { activeId = profiles.first?.id }
        rebuildClient()
    }

    var active: ServerProfile? { profiles.first { $0.id == activeId } }

    var isSignedIn: Bool { client != nil }

    var isAdmin: Bool { user?.policy?.isAdministrator ?? false }

    var canDownload: Bool { user?.policy?.enableContentDownloading ?? true }

    func observeActive(_ listener: @escaping (ServerProfile?) -> Void) {
        listeners.append(listener)
    }

    /** A client for a server that isn't signed in yet. */
    func anonymousClient(_ url: URL) -> JellyfinClient {
        JellyfinClient(baseURL: url, info: info)
    }

    private func rebuildClient() {
        guard let profile = active, let url = profile.url, let token = Keychain.get(profile.id) else {
            client = nil
            user = nil
            return
        }
        client = JellyfinClient(baseURL: url, info: info, token: token, userId: profile.userId)
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        defaults.set(activeId, forKey: Self.activeKey)
    }

    private func changed() {
        generation += 1
        let profile = active
        listeners.forEach { $0(profile) }
    }

    /** Keep the account that just signed in, and switch to it. */
    @discardableResult
    func signedIn(_ result: AuthenticationResult, server url: URL, system: PublicSystemInfo?) -> ServerProfile {
        let serverId = result.serverId ?? result.user.serverId ?? system?.id ?? url.absoluteString
        let id = "\(serverId)|\(result.user.id)"
        let profile = ServerProfile(
            id: id,
            serverId: serverId,
            serverName: system?.serverName ?? url.host ?? "Jellyfin",
            serverUrl: url.absoluteString,
            userId: result.user.id,
            username: result.user.name,
            userImageTag: result.user.primaryImageTag,
            addedAt: profiles.first { $0.id == id }?.addedAt ?? Date()
        )
        _ = Keychain.set(result.accessToken, for: id)
        profiles.removeAll { $0.id == id }
        profiles.append(profile)
        activeId = id
        save()
        rebuildClient()
        user = result.user
        serverVersion = system?.version
        changed()
        return profile
    }

    func switchTo(_ id: String) {
        guard id != activeId, profiles.contains(where: { $0.id == id }) else { return }
        activeId = id
        save()
        rebuildClient()
        changed()
        Task { await refreshUser() }
    }

    /** Sign out of one account (the token is ended on the server too). */
    func signOut(_ id: String? = nil) {
        guard let id = id ?? activeId else { return }
        if id == activeId, let client { Task { await client.logout() } }
        Keychain.delete(id)
        profiles.removeAll { $0.id == id }
        if activeId == id {
            activeId = profiles.last?.id
            rebuildClient()
            changed()
        }
        save()
    }

    func rename(_ id: String, server name: String) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].serverName = name
        save()
    }

    /** Ask the server who we are: preferences and permissions, and whether the token still works. */
    func refreshUser() async {
        guard let client else { return }
        do {
            let me = try await client.me()
            if client === self.client { user = me }
            if let system = try? await client.publicInfo(timeout: 10), client === self.client {
                serverVersion = system.version
                if let index = profiles.firstIndex(where: { $0.id == activeId }), let name = system.serverName, profiles[index].serverName != name {
                    profiles[index].serverName = name
                    save()
                }
            }
        } catch JellyfinError.unauthorized {
            // The token was revoked on the server: sign in again.
            if client === self.client, let id = activeId {
                Keychain.delete(id)
                self.client = nil
                changed()
            }
        } catch {
            // Offline or unreachable: keep going with what we have.
        }
    }
}

/** The app's version, e.g. "1.0.0". */
let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
let appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
