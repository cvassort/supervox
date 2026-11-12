import Foundation
import SupervoxCore

/// Partagée par `transcribe` et `latency` : tout message d'erreur qui sort d'une commande (rapport, JSON, console)
/// passe par elle quand un endpoint est configuré.
/// Retire d'un message l'adresse de l'endpoint (complète et nom d'hôte) et la clé.
func endpointRedactor(_ config: EndpointConfig) -> (String) -> String {
    let address = config.baseURL.absoluteString
    var secrets = [address, address.hasSuffix("/") ? String(address.dropLast()) : address]
    if let host = config.baseURL.host(), !host.isEmpty { secrets.append(host) }
    let key = config.apiKey
    return { text in
        var out = key.isEmpty ? text : text.replacingOccurrences(of: key, with: "***")
        for secret in secrets where !secret.isEmpty {
            out = out.replacingOccurrences(of: secret, with: "<endpoint>", options: .caseInsensitive)
        }
        return out
    }
}
