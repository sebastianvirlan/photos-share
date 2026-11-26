import Foundation
import Observation
import Security

/// The share this phone is connected to. The address lives in UserDefaults and the session
/// token in the Keychain; the password itself is never stored.
@MainActor @Observable
final class AppModel {
    private(set) var api: API?
    private(set) var info: ServerInfo?

    private static let addressKey = "serverAddress"

    /// The Hidden album was unlocked with Face ID; locked again when the app goes to the background.
    var hiddenUnlocked = false

    init() {
        if let s = UserDefaults.standard.string(forKey: Self.addressKey), let base = URL(string: s) {
            api = API(base: base, token: Keychain.read(account: base.absoluteString))
        }
    }

    var address: String? { api?.base.absoluteString }

    /// Checks the address; returns whether a password is needed. Throws for anything else.
    func probe(_ typed: String) async throws -> (URL, needsPassword: Bool) {
        guard let typedBase = API.normalise(typed) else { throw APIError.badAddress }
        let base = try await API(base: typedBase, token: nil).resolved().base
        do {
            _ = try await API(base: base, token: nil).info()
            return (base, false)
        } catch APIError.needsPassword {
            return (base, true)
        }
    }

    func connect(base: URL, password: String?) async throws {
        var token: String?
        if let password {
            token = try await API(base: base, token: nil).login(password: password)
        }
        let api = API(base: base, token: token)
        info = try await api.info()
        if let token { Keychain.save(token, account: base.absoluteString) }
        UserDefaults.standard.set(base.absoluteString, forKey: Self.addressKey)
        UserDefaults.standard.set(base.absoluteString, forKey: Self.lastKey)
        notice = nil
        self.api = api
    }

    func disconnect() {
        if let address { Keychain.delete(account: address) }
        UserDefaults.standard.removeObject(forKey: Self.addressKey)
        api = nil
        info = nil
    }

    /// Shown on the connect screen after being signed out.
    var notice: String?
    /// Kept so the connect screen can offer it again.
    var lastAddress: String? { UserDefaults.standard.string(forKey: Self.lastKey) }
    private static let lastKey = "lastServerAddress"

    /// Called when the server refuses the saved token (the password was changed on the Mac,
    /// or a password was added to a share that had none).
    func signedOut() {
        guard let address else { return }
        UserDefaults.standard.set(address, forKey: Self.lastKey)
        disconnect()
        notice = "The Mac asked for the password again. It may have been changed."
    }

    func refreshInfo() async {
        guard let api else { return }
        info = try? await api.info()
    }
}

enum Keychain {
    private static let service = "photos-share.session"

    static func save(_ value: String, account: String) {
        delete(account: account)
        let item: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                     kSecAttrAccount: account, kSecValueData: Data(value.utf8),
                                     kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        var out: CFTypeRef?
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account, kSecReturnData: true]
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
                                      kSecAttrAccount: account]
        SecItemDelete(query as CFDictionary)
    }
}
