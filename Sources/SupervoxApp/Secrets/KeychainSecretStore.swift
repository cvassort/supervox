import Foundation
import Security

/// Résultat d'un appel `SecItem*`, ramené à ce que le code appelant doit distinguer.
enum SecretOutcome: Equatable {
    case success
    case notFound
    case failure(SecretError)
}

/// Secrets dans le trousseau de l'utilisateur : un mot de passe générique par compte, dans le
/// trousseau fichier classique. Le trousseau à protection des données (`kSecUseDataProtectionKeychain`)
/// exige un profil d'approvisionnement que cette application n'a pas : on ne le demande donc jamais.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    static func outcome(forStatus status: OSStatus) -> SecretOutcome {
        switch status {
        case errSecSuccess: .success
        case errSecItemNotFound: .notFound
        case errSecUserCanceled, errSecAuthFailed: .failure(.denied)
        default: .failure(.unavailable(status: status))
        }
    }

    public func read(account: String) throws -> String? {
        var query = identity(account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        switch Self.outcome(forStatus: SecItemCopyMatching(query as CFDictionary, &result)) {
        case .notFound: return nil
        case .failure(let error): throw error
        case .success:
            guard let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
                throw SecretError.unavailable(status: errSecDecode)
            }
            return secret
        }
    }

    public func write(_ secret: String, account: String) throws {
        let data = Data(secret.utf8)
        let update = [kSecValueData: data] as [CFString: Any]

        switch Self.outcome(forStatus: SecItemUpdate(identity(account: account) as CFDictionary, update as CFDictionary)) {
        case .success: return
        case .failure(let error): throw error
        case .notFound: break
        }

        var item = identity(account: account)
        item[kSecValueData] = data
        let added = SecItemAdd(item as CFDictionary, nil)
        if added == errSecDuplicateItem {
            // Une autre écriture a créé l'entrée entre la mise à jour et l'ajout : on met à jour.
            if case .failure(let error) = Self.outcome(
                forStatus: SecItemUpdate(identity(account: account) as CFDictionary, update as CFDictionary))
            {
                throw error
            }
            return
        }
        if case .failure(let error) = Self.outcome(forStatus: added) { throw error }
    }

    public func delete(account: String) throws {
        switch Self.outcome(forStatus: SecItemDelete(identity(account: account) as CFDictionary)) {
        case .success, .notFound: return
        case .failure(let error): throw error
        }
    }

    private func identity(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
