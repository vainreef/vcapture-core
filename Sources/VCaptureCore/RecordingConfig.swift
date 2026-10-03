import Foundation
import CoreGraphics
import ScreenCaptureKit

public enum ResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case native = "Native Resolution"
    case fhd1080p = "1080p FHD (1920×1080)"
    case hd720p = "720p HD (1280×720)"

    public var id: String { rawValue }

    public func calculateDimensions(originalWidth: Int, originalHeight: Int) -> (width: Int, height: Int) {
        let origW = max(2, originalWidth)
        let origH = max(2, originalHeight)
        let aspect = Double(origW) / Double(origH)

        var targetW: Int
        var targetH: Int

        switch self {
        case .native:
            targetW = origW
            targetH = origH
        case .fhd1080p:
            if origW >= origH {
                targetW = min(origW, 1920)
                targetH = Int(Double(targetW) / aspect)
            } else {
                targetH = min(origH, 1080)
                targetW = Int(Double(targetH) * aspect)
            }
        case .hd720p:
            if origW >= origH {
                targetW = min(origW, 1280)
                targetH = Int(Double(targetW) / aspect)
            } else {
                targetH = min(origH, 720)
                targetW = Int(Double(targetH) * aspect)
            }
        }

        // H.264/HEVC hardware encoders strictly require even dimensions
        if targetW % 2 != 0 { targetW -= 1 }
        if targetH % 2 != 0 { targetH -= 1 }

        return (max(2, targetW), max(2, targetH))
    }
}

public enum FrameRatePreset: Int, CaseIterable, Identifiable, Sendable {
    case fps60 = 60
    case fps30 = 30

    public var id: Int { rawValue }
    public var label: String { "\(rawValue) FPS" }
}

public struct DisplayOption: Identifiable, Sendable, Equatable {
    public let displayID: CGDirectDisplayID
    public let name: String
    public let bounds: CGRect
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let isMain: Bool

    public var id: CGDirectDisplayID { displayID }

    public var label: String {
        let tag = isMain ? " (Main Display)" : ""
        return "\(name)\(tag) — \(pixelWidth)×\(pixelHeight)"
    }
}

public struct RecordingConfig: Sendable {
    public var selectedDisplayID: CGDirectDisplayID
    public var displayBounds: CGRect
    public var originalPixelWidth: Int
    public var originalPixelHeight: Int
    public var resolution: ResolutionPreset
    public var frameRate: FrameRatePreset
    public var captureSystemAudio: Bool
    public var captureMicrophone: Bool
    public var captureInputEvents: Bool

    public init(
        selectedDisplayID: CGDirectDisplayID = CGMainDisplayID(),
        displayBounds: CGRect = .zero,
        originalPixelWidth: Int = 1920,
        originalPixelHeight: Int = 1080,
        resolution: ResolutionPreset = .native,
        frameRate: FrameRatePreset = .fps60,
        captureSystemAudio: Bool = true,
        captureMicrophone: Bool = false,
        captureInputEvents: Bool = true
    ) {
        self.selectedDisplayID = selectedDisplayID
        self.displayBounds = displayBounds
        self.originalPixelWidth = originalPixelWidth
        self.originalPixelHeight = originalPixelHeight
        self.resolution = resolution
        self.frameRate = frameRate
        self.captureSystemAudio = captureSystemAudio
        self.captureMicrophone = captureMicrophone
        self.captureInputEvents = captureInputEvents
    }

    public var targetDimensions: (width: Int, height: Int) {
        resolution.calculateDimensions(
            originalWidth: originalPixelWidth,
            originalHeight: originalPixelHeight
        )
    }
}
