import Foundation
import Testing
@testable import SupervoxCore

/// Les phrases de `DictationSession.describe`, déplacées sur l'erreur : chacune porte un test de texte exact, parce que
/// ces phrases sont montrées dans le panneau.
@Test(arguments: [
    (AudioCaptureError.microphoneAccessDenied("accès refusé : l'autoriser"), "accès refusé : l'autoriser"),
    (AudioCaptureError.noInputDevice, "aucun micro utilisable n'a été trouvé"),
    (AudioCaptureError.alreadyRunning, "le micro est déjà utilisé"),
    (AudioCaptureError.engineFailed("code d'erreur du système : -10868"), "le moteur audio a échoué (code d'erreur du système : -10868)"),
    (AudioCaptureError.notRunning, "le moteur audio n'est pas démarré"),
])
func eachCaptureErrorHasItsFixedSentence(error: AudioCaptureError, sentence: String) {
    #expect(error.reason == sentence)
}
