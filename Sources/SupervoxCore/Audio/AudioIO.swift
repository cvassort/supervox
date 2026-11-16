import Foundation

/// Comment une lecture s'est terminée.
public enum PlaybackEnd: Equatable, Sendable {
    /// Le dernier échantillon est sorti du périphérique (`.dataPlayedBack`).
    case played
    /// `stopPlayback()` ou `stop()` l'a coupée avant.
    case stopped
}
