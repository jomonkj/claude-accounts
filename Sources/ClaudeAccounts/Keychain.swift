import Foundation
import Security

/// Reads the "Claude Safe Storage" password, which encrypts the Claude cookies (docs/usage-live.md).
/// It uses the Keychain API, so macOS asks once and ties the permission to this app.
/// Never use /usr/bin/security for this: "Always Allow" on that tool lets any process read the key.
enum Keychain {
    enum Failure: Error, Equatable {
        case denied, notFound, other(OSStatus)

        var message: String {
            switch self {
            case .denied: "Live usage needs access to the \"Claude Safe Storage\" key. Allow it in the macOS dialog."
            case .notFound: "The \"Claude Safe Storage\" key was not found. Open Claude one time, then try again."
            case .other(let s): "Cannot read the \"Claude Safe Storage\" key (error \(s))."
            }
        }
    }

    /// Blocks while macOS shows its dialog, so call it off the main thread.
    static func claudeSafeStorage() -> Result<String, Failure> {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let pw = String(data: data, encoding: .utf8), !pw.isEmpty else {
                return .failure(.notFound)
            }
            return .success(pw)
        case errSecItemNotFound: return .failure(.notFound)
        case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed: return .failure(.denied)
        default: return .failure(.other(status))
        }
    }
}
