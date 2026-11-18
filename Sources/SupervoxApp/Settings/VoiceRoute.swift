import Foundation
import SupervoxCore

/// Pourquoi une voix de fournisseur est dite par le système.
public enum SystemReason: Equatable, Sendable {
    /// Le fournisseur de la voix n'est plus dans les réglages.
    case providerRemoved
    /// Le fournisseur n'a pas de synthèse (format Anthropic).
    case providerCannotSpeak
    /// Le modèle ou l'identifiant de la voix est absent ou blanc : rien ne dit quoi demander.
    case incomplete
}

/// Qui dit le texte de Supervox, décidé à partir des réglages seuls.
public enum VoiceRoute: Equatable, Sendable {
    /// La voix du système, dans cette langue ; `identifier` `nil` : la meilleure voix de la langue. `because` `nil` : la voix choisie
    /// est une voix du système ; sinon, c'est le repli d'une voix de fournisseur, et `identifier` est toujours `nil` (un identifiant
    /// de fournisseur ne désigne pas une voix du système).
    case system(language: String, identifier: String?, because: SystemReason?)
    /// La voix de ce fournisseur : modèle, identifiant et paramètres de la forme normalisée.
    case provider(Provider, ProviderVoice)
}

extension VoiceChoice {
    /// LA règle « qui parle vraiment » : tout lecteur qui doit savoir si le texte dit par Supervox part chez un fournisseur passe par
    /// elle (la résolution de l'entretien, la ligne de vie privée de l'onglet Entretien). Lit la forme normalisée. Ordre des
    /// replis : fournisseur supprimé, puis sans synthèse, puis voix incomplète.
    ///
    /// Pure : elle ne lit que les réglages, jamais le trousseau. Une voix `.provider` dont la clé manque (ou que le trousseau refuse)
    /// est dite par le système à l'entretien (`InterviewSetup.resolve`), alors que la ligne de vie privée de l'onglet nomme son
    /// fournisseur : sur-avertissement résiduel admis (on annonce un envoi qui n'a pas lieu, jamais l'inverse).
    public func route(in settings: AppSettings) -> VoiceRoute {
        let choice = normalized
        guard let providerID = choice.providerID else {
            return .system(language: choice.language, identifier: choice.identifier, because: nil)
        }
        func fallback(_ reason: SystemReason) -> VoiceRoute {
            .system(language: choice.language, identifier: nil, because: reason)
        }
        guard let provider = settings.providers.first(where: { $0.id == providerID }) else { return fallback(.providerRemoved) }
        switch provider.kind {
        case .anthropic: return fallback(.providerCannotSpeak)
        case .openAICompatible: break
        }
        guard let model = choice.model, let identifier = choice.identifier else { return fallback(.incomplete) }
        return .provider(provider, ProviderVoice(model: model, identifier: identifier, extra: choice.extra))
    }

    /// LA règle « cette ligne est la voix en vigueur ». Deux voix de fournisseur sont la même si leurs formes normalisées sont égales
    /// (`==` : fournisseur, modèle, identifiant, langue, genre, paramètres ; les champs inconnus ne comptent pas). Deux voix du système
    /// sont la même si l'identifiant (normalisé) et la langue sont égaux, la langue comparée sans casse, `_` et `-` confondus, rien
    /// d'autre (`fr-FR` et `fr-CA` sont deux voix) ; genre et paramètres ne comptent pas. Une voix du système et une voix de
    /// fournisseur ne sont jamais la même. `settings.voice` ne porte pas d'identité de ligne : si plusieurs voix enregistrées sont la
    /// même voix, la première de la liste est la voix en vigueur.
    public func isSameVoice(as other: VoiceChoice) -> Bool {
        let lhs = normalized
        let rhs = other.normalized
        switch (lhs.providerID, rhs.providerID) {
        case (nil, nil):
            func languageKey(_ language: String) -> String { language.lowercased().replacingOccurrences(of: "_", with: "-") }
            return lhs.identifier == rhs.identifier && languageKey(lhs.language) == languageKey(rhs.language)
        case (.some, .some):
            return lhs == rhs
        default:
            return false
        }
    }
}
