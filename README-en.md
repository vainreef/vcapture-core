# VCaptureCore

[English Version](README-en.md) | [中文说明](README.md) | [Engineering Whitepaper (EN)](ENGINEERING-DEEP-DIVE-en.md) | [深度工程白皮书 (中文)](ENGINEERING-DEEP-DIVE-zh.md)

**VCaptureCore** is an industrial-grade, high-performance native screen recording audio/video pipeline library designed specifically for macOS (Apple Silicon architecture).

It fundamentally solves the low-level stutter, hardware backpressure resonance, audio-video desynchronization, and cross-track multiplexer deadlocks encountered when using native `ScreenCaptureKit` + `AVAssetWriter` under extreme **4K UHD (3840×2160) @ 180Hz ProMotion gaming display** workloads.

---

## 🎯 Key Problems Solved & Engineering Benchmarks

In traditional macOS screen recording implementations, violent window dragging or rapid scrolling on high-refresh 4K screens triggers severe A/V drift, dozens of hardware backpressure stalls per second, and periodic visual stutter. VCaptureCore achieves the following uncompromising industrial benchmarks:

| Metric | Traditional / Naive Approaches | VCaptureCore Production Baseline |
| :--- | :--- | :--- |
| **Resolution & Color** | Downscaled to 1080p or washed-out NV12 | **Native 4K (3840×2160) @ 32BGRA Full Range 4:4:4** |
| **Framerate Model** | Variable Frame Rate (VFR) causing editor drift | **Strict 60.000000 FPS CFR**, constant 16.6667ms frame intervals |
| **Hardware Backpressure** | Burst writes induce **1066 backpressure stalls** | **0 stalls (ZERO backpressure)**, no FIFO queue saturation |
| **Hardware Dropped Frames** | 5.47% drop rate (116 frames) under motion | **0.06% (only 1 frame in 30s extreme stress test)** |
| **Timeline Continuity** | 50 slot discontinuity gaps (freeze-and-jump) | **0 timeline holes**, 100% monotonically continuous |
| **A/V Sync Drift** | Audio desynchronizes by 1.55 ~ 1.74 seconds | **Constant 12.71 ms** (strictly within broadcast $\le 16.7\text{ms}$ lockstep) |
| **Delivery Model** | Lengthy second-pass re-encoding required | **Stop & Deliver**, streaming direct disk write, zero post-transcoding |

---

## 🏗️ Core Architecture & Key Innovations

```text
  [1. Producer Layer: SCStream 180Hz Direct Passthrough]
     └─► minimumFrameInterval = .zero (delivers every 5.55ms)
     └─► deposit() ──► Atomic pointer swap (< 5µs, zero blocking on capture queue)

  [2. Memory Pool: 16-Frame Anti-Jitter Ring Pool (Elastic Horizon Queue)]
     └─► 16 frames capacity (~530MB uncompressed 4K RAM), 88.8ms temporal span
     └─► Nearest-PTS matching (accommodates 0.44ms AppKit drag jitter, 0 fake freezes)

  [3. Consumer Layer: Strict Single-Tick Engine (Tick-Lock 60 FPS CFR)]
     └─► DispatchSourceTimer fires every 16.6667ms
     └─► 1 Tick = 1 Video Frame + 1 Audio Slice (strictly forbids burst catch-up)
     └─► Microsecond probe (<= 3ms), never starves the dispatch queue with sleeps

  [4. Hardware Channel: Apple Silicon Native 4K HEVC Hardware Acceleration]
     └─► Bound to AVVideoCodecType.hevc (M-series dedicated matrix media engine)
     └─► 4K single-frame encode latency of only 2~3ms (slashing compute by 85% vs H.264)
     └─► Explicit end-to-end ITU-R BT.709 color metadata binding

  [5. Dual-Track Pacing: Millisecond-Accurate A/V Lockstep (AudioPacer)]
     └─► Real audio committed synchronously with video in consumer tick: (slot + 1) / 60
     └─► Exact binary descriptor alignment (48kHz, Non-Interleaved Float32)
     └─► Permanently eliminates AVAssetWriter 200ms bidirectional interleaving deadlocks
```

---

## 📦 Module Overview

| File | Responsibility |
| :--- | :--- |
| `FrameSlotBuffer.swift` | Zero-copy ring buffer (16 frames) providing Nearest-PTS elastic temporal harvesting. |
| `AudioPacer.swift` | Dual-track millisecond lockstep audio pacer; synthesizes aligned silence to prevent interleaving stalls. |
| `ScreenRecorder.swift` | Core recording driver pipeline (producer-consumer decoupling, HEVC setup, Tick-Lock 60fps scheduler). |
| `RecordingConfig.swift` | Recording presets, display geometry, and hardware even-dimension alignment calculations. |
| `RecordingDiagnostics.swift` | Nanosecond-level asynchronous telemetry counters (backpressures, drops, framerate statistics). |
| `TimelineLogger.swift` | Microsecond-level per-frame timeline CSV logger (provides empirical CFR and drift proof). |
| `SourceStreamTracker.swift` | Producer-side raw arrival timestamp tracker. |

---

## 🚀 Quick Start (Swift Package Manager)

### 1. Add Package Dependency
Add this sub-repository to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../VCaptureCore") // Or remote Git repository URL
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["VCaptureCore"]
    )
]
```

### 2. Basic Usage

```swift
import VCaptureCore
import CoreGraphics

// 1. Configure recording parameters
var config = RecordingConfig(
    selectedDisplayID: CGMainDisplayID(),
    resolution: .native,    // Preserve native 4K resolution
    frameRate: .fps60,      // Strict 60 FPS CFR
    captureSystemAudio: true
)

// 2. Initialize the core screen recorder
let outputURL = URL(fileURLWithPath: "/path/to/output/video.mp4")
let recorder = ScreenRecorder(config: config, outputURL: outputURL)

// 3. Start recording asynchronously
Task {
    do {
        try await recorder.startCapture()
        print("Screen recording running at 60 FPS CFR.")
        
        // Record for desired duration...
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
        // 4. Stop and deliver (container finalized immediately, zero re-encoding)
        try await recorder.stopCapture()
        print("Recording saved to \(outputURL.path)")
    } catch {
        print("Capture failed: \(error)")
    }
}
```

---

## 📖 Deep-Dive Engineering Documentation

For the full physics derivations, root-cause dissections of all 27 technical traps (e.g. WindowServer throttling watchdog, real-time FIFO saturation, 88.8ms temporal pool eviction, 200ms bidirectional interleaving deadlocks), see:
- [Complete Engineering Deep Dive Whitepaper (English)](ENGINEERING-DEEP-DIVE-en.md)
- [完整工程深度剖析白皮书 (中文版)](ENGINEERING-DEEP-DIVE-zh.md)

---

## 📄 License

MIT License.
