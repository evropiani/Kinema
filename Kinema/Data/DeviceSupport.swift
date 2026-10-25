import AVFoundation
import CoreMedia
import UIKit
import VideoToolbox

/** What this phone's decoders and screen can do, for the device profile sent to the server. */
enum DeviceSupport {
    static let capabilities: DeviceCapabilities = {
        let hevc = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
        let av1: Bool = {
            if #available(iOS 17.0, *) { return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) }
            return false
        }()
        let dolbyVision = VTIsHardwareDecodeSupported(kCMVideoCodecType_DolbyVisionHEVC)
        return DeviceCapabilities(hevc: hevc, av1: av1, dolbyVision: dolbyVision, hdr: hevc, maxAudioChannels: 6)
    }()

    /** Whether the screen shows HDR (otherwise HDR video is tone-mapped). */
    static var hdrScreen: Bool { AVPlayer.eligibleForHDRPlayback }

    /** "HEVC · Dolby Vision · AV1", for Settings → About. */
    static var summary: String {
        var parts = ["H.264"]
        if capabilities.hevc { parts.append("HEVC") }
        if capabilities.av1 { parts.append("AV1") }
        if capabilities.dolbyVision { parts.append("Dolby Vision") }
        if hdrScreen { parts.append("HDR screen") }
        return parts.joined(separator: " · ")
    }
}
