import Foundation

/// Whether this phone will let the pairing screen use its camera.
///
/// Kept free of AVFoundation so the decision — and the wording the person
/// holding the phone reads — can be tested without camera hardware. The iOS
/// view translates the system's authorization status into this.
public enum CameraPermission: Equatable, Sendable {
    case undetermined
    case granted
    case denied
    case restricted
}

/// What the pairing screen should do about the camera, and what to say when it
/// cannot be used.
///
/// A scanner that fails silently is indistinguishable from one pointed at a
/// code it cannot read, so every state that is not `ready` carries wording
/// that names the cause and the way out.
public enum CameraAvailability: Equatable, Sendable {
    /// The camera can run; show the viewfinder.
    case ready
    /// Nobody has been asked yet.
    case needsPermission
    case denied
    case restricted
    /// The camera exists but could not be opened.
    case unavailable

    public static func of(_ permission: CameraPermission, hasCamera: Bool) -> CameraAvailability {
        guard hasCamera else { return .unavailable }
        switch permission {
        case .granted: return .ready
        case .undetermined: return .needsPermission
        case .denied: return .denied
        case .restricted: return .restricted
        }
    }

    /// `nil` while the camera is usable; otherwise what to show instead of a
    /// black rectangle.
    public var message: String? {
        switch self {
        case .ready, .needsPermission:
            return nil
        case .denied:
            return
                "RemoteAI cannot use the camera. Turn it on in Settings › RemoteAI › Camera, "
                + "or paste the pairing code below instead."
        case .restricted:
            return
                "Camera access is restricted on this phone, so the code cannot be scanned. "
                + "Paste the pairing code below instead."
        case .unavailable:
            return
                "The camera could not be opened. Paste the pairing code below instead."
        }
    }

    /// Whether the viewfinder should be on screen at all.
    public var showsViewfinder: Bool { self == .ready }
}
