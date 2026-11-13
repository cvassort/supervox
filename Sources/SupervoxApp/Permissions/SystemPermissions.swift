import AVFoundation
import ApplicationServices

/// Les vraies permissions du système : micro (AVFoundation) et Accessibilité (`AXIsProcessTrusted`).
public struct SystemPermissions: PermissionsProbe {
    public init() {}

    public func microphone() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    public func accessibility() -> PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    public func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func promptAccessibility() {
        // Clé `kAXTrustedCheckOptionPrompt`, écrite en clair : la constante C est une variable
        // globale mutable, que Swift 6 refuse de lire hors isolation.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
