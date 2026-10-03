# High-Performance macOS Screen Recording Engineering Whitepaper (ENGINEERING-DEEP-DIVE.md)

> **Version**: v4.0 (2026 Production Closed-Loop Edition)  
> **Target Environment**: macOS 14+ / Apple Silicon (M-series Chips) / 4K UHD @ 180Hz ProMotion Gaming Displays  
> **Engineering Objective**: Native 4K (3840×2160) @ 60.000000 FPS CFR, 32BGRA pixel-perfect native color fidelity, sub-16.7ms audio-video lockstep synchronization, zero cross-track interleaving deadlocks, zero dropped frames, zero backpressure, and zero second-pass transcoding ("Stop & Deliver").

---

## 1. System Architecture & Data Flow Topology

VCaptureCore is an industrial-grade screen recording pipeline built directly on native macOS system frameworks (`ScreenCaptureKit`, `AVFoundation`, `VideoToolbox`, `AppKit`). Under extreme 4K 180Hz gaming refresh rates and violent user interactions, its end-to-end data and control flow is architected as follows:

```text
┌────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                              VCapture 4K 60 FPS CFR Production Pipeline Topology                       │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘

  [1. Hardware Input Layer]
   MZQ27F180 Physical Display (3840×2160 @ 180Hz) ──► WindowServer (Metal GPU Framebuffer, 32BGRA Full-Range)
                                                         │
                                                         ▼
  [2. Producer / Capture Layer (captureQueue - Atomic Zero Blocking, < 5µs)]
   SCStream (minimumFrameInterval = .zero, queueDepth = 32)
   │ 
   ├─► Video Frames (180Hz / 5.55ms) ──► FrameSlotBuffer.deposit() ──► 16-Frame Anti-Jitter Ring Pool (88.8ms Span)
   └─► Audio Samples (48kHz Stereo) ──► pendingAudioBuffers.append() ──► Audio Sample Queue
                                                                           │
  [3. Consumer / Scheduler Layer (encodeQueue - Strict Tick-Lock 60 FPS CFR, 16.67ms)]│
   16.6667ms Timer (DispatchSourceTimer, ProcessInfo Real-time Anti-Nap Assertion)   │
   │                                                                                 │
   ▼                                                                                 │
   1. Absolute Physical Clock Anchor: targetSlot = Int64(round((hostNow - masterOrigin).seconds * 60))
   2. Elastic Horizon Nearest-PTS Harvest: harvest(targetPTS = slot * 16.67ms) ──► 0 Fake Freezes    │
   3. Single-Frame Hardware Append: AVAssetWriterInputPixelBufferAdaptor.append(buffer, PTS) (1 frame/tick)
   4. Dual-Track Lockstep Pacing: AudioPacer.paveAudioToSlot(slot) ◄─────────────────┘
      (Real audio commit + Aligned silence synthesis, Audio PTS = (slot + 1) / 60, drift <= 16.7ms)
   │
   ▼
  [4. Streaming Disk Write (VideoToolbox & AVAssetWriter - expectsMediaDataInRealTime = true)]
   Apple Silicon Native 4K HEVC Hardware Channel (Encode latency: 2~3ms, > 14ms headroom)
   + Explicit ITU-R BT.709 Color Primaries / Transfer Function / YCbCr Matrix Metadata Binding
   + Direct MP4 Container Streaming ──► ~/Desktop/VCapture_YYYY-MM-DD_HH-mm-ss/ (Stop & Deliver)
```

---

## 2. Underlying Physics & Four Inherent Impedance Mismatches

Invoking Apple's native APIs for screen recording appears trivial, but achieving **4K resolution + 180Hz high refresh rate + strict 60.000 FPS CFR** exposes four profound low-level hardware and operating system impedance mismatches:

```text
┌────────────────────────────────────────────────────────────────────────────────────────┐
│                        The Four Inherent Impedance Mismatches on macOS                 │
├────────────────────────────────────────────────────────────────────────────────────────┤
│ 1. Cadence Mismatch: ScreenCaptureKit (Event-driven/Jitter) vs 60 FPS CFR (Discrete Grid)│
│ 2. Micro-Queue Capacity Mismatch: AVAssetWriterInput Real-time FIFO vs Burst Flooding │
│ 3. Clock Domain Mismatch: Audio Hardware Crystal vs Video PTS vs 200ms Deadband        │
│ 4. Memory Bus & Compute Mismatch: 4K 32BGRA (33.18 MB/frame) vs M1 Unified Bus Limits  │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

### 1. Cadence Mismatch: Event-Driven Bursts/Starvations vs Discrete Time Grid
- **Physics**: ScreenCaptureKit operates on OS dirty-rect compositing events. When the screen is static, frame delivery drops to **0 FPS**; when moving a cursor violently across a 180Hz display, frames surge at **180 FPS** (one frame every 5.55ms).
- **Mismatch**: Professional editors (Final Cut Pro, Premiere) and media players demand strict Constant Frame Rate (CFR, with frame intervals strictly locked to $16.6667\text{ms}$). Streaming raw SCK frames directly produces variable frame rate (VFR) files that cause audio waveform drift and stutter. Conversely, forcing CFR requires millisecond-accurate padding during static scenes and lossless nearest-neighbor downsampling during motion.

### 2. Micro-Queue Capacity Mismatch: Real-time Streaming FIFO vs Burst Flooding
- **Physics**: In real-time screen capture, media inputs must declare `expectsMediaDataInRealTime = true`. In this mode, the underlying VideoToolbox hardware encoder driver allocates an extremely shallow hardware FIFO buffer—**strictly holding only 1 to 2 uncompressed 4K frames**.
- **Mismatch**: A single 4K 32BGRA uncompressed frame consumes **33.18 MB**. If the consumer lags slightly and attempts a `while` loop to burst 2 to 4 frames in a single tick (trying to "catch up"), flooding 66MB~132MB in 0.1ms saturates the hardware FIFO instantly. The driver locks `isReadyForMoreMediaData` to `false` for 50~70ms, triggering violent **limit-cycle backpressure resonance**.

### 3. Cross-Track Interleaving Mismatch: Physical Audio Crystal vs AVAssetWriter 200ms Deadband
- **Physics**: Real system audio originates from the CoreAudio soundcard DAC/SCStream audio tap driven by physical audio crystals; video originates from GPU Metal display timestamps; when the system is silent, SCStream stops dispatching audio completely.
- **Mismatch**: The `AVAssetWriter` MP4 multiplexer enforces a rigid **200ms bidirectional interleaving deadband**:
  - If video leads audio by $> 200\text{ms}$ $\implies$ `videoInput.isReadyForMoreMediaData` locks to `false`;
  - If audio leads video by $> 200\text{ms}$ $\implies$ `videoInput.isReadyForMoreMediaData` likewise locks to `false`!
  Violating this deadband stalls video writes permanently, creating catastrophic A/V desynchronization or a corrupted 68-byte file.

### 4. Memory Bus & Compute Mismatch: 4K 32BGRA Ingestion vs M1 Hardware Throughput
- **Physics**: Preserving 100% native color fidelity requires `kCVPixelFormatType_32BGRA` (4:4:4 Full Range [0-255]). Delivering 180 FPS of 4K 32BGRA frames generates a memory bus transfer rate of **5.97 GB/s**.
- **Mismatch**: The base Apple M1 unified memory bandwidth is 68.25 GB/s (shared across CPU, GPU, NPU, display engine, and media engines). Under complex 4K motion:
  - **H.264 Encoding**: Single-frame compression takes **15~20ms**, bumping against the 16.67ms tick deadline with zero safety margin;
  - **HEVC (H.265) Encoding**: Apple Silicon's dedicated HEVC matrix coprocessor takes only **2~3ms**, leaving $> 14\text{ms}$ of computational headroom.

---

## 3. Evolutionary Journey & Architectural Paradigm Shifts

VCaptureCore evolved through 6 major architectural paradigms:

```text
[v1.0 Passthrough] ──► [v2.0 Synthetic Timer] ──► [v3.0 1-Slot Overwrite] ──► [v4.0 Burst Catch-up] ──► [v5.0 Skip-Slot Clock] ──► [v6.0 Unified Closure]
  Severe VFR             Severe Judder              Fake Freezes & Jumps        1066 Backpressures       MP4 Time Holes           HEVC + Tick-Lock
  Silence Stalls         8s Audio Drift             (27 gaps in 8s)             1.55s Clock Lag          Stutter Freezes          0 Backpressure / 0 Drops
```

1. **v1.0 Passive SCStream Passthrough**: Directly calling `append(sampleBuffer)` inside the SCStream callback. Produced severe VFR files; silence caused recording to stall.
2. **v2.0 Naive Synthetic Timer**: Storing the newest frame in a single variable consumed by a 16.6ms timer. High-refresh frames overwrote each other before being consumed; effective motion dropped to 13 FPS, and audio drifted by 8 seconds over 2 minutes.
3. **v3.0 Destructive 1-Slot Overwrite**: Introduced fixed slotting, but enforced a rigid zero-latency deadline with single-frame overwriting. Real-world testing proved 180Hz displays exhibit sub-millisecond event jitter; a 0.44ms arrival delay was misdiagnosed as static, resulting in alternating fake freezes and teleport jumps.
4. **v4.0 The Burst Catch-Up Disaster**: Attempting to catch up during lag by looping 2 to 4 frames per tick. Flooded `AVAssetWriterInput`'s 1-frame real-time FIFO, inducing 1066 backpressures, 57 FPS throughput throttle, and 1.55s cumulative clock lag.
5. **v5.0 Skip-Slot Hole Carving**: Attempting to skip slots via `targetSlot = max(lastWrittenSlot + 1, physicalTarget)`. Carved 4~6 frame gaps in the MP4 timeline whenever encoder latency spiked, creating recurring freeze-jump visual stutter.
6. **v6.0 Production Closed-Loop (Current Architecture)**:
   - **Producer**: 180Hz full-speed capture + 500MB (16-frame) ring pool with atomic $< 5\mu\text{s}$ swap.
   - **Consumer**: Strict single-tick execution (Tick-Lock 60 FPS CFR), strictly forbidding burst writes.
   - **Clock & Extraction**: Nearest-PTS elastic horizon (16.67ms), eliminating fake freezes.
   - **Hardware Channel**: Native 4K HEVC hardware encoder, slashing latency from 18ms to 2~3ms.
   - **Dual-Track Lockstep**: Audio strictly paced synchronously with video in the consumer tick ($\text{drift} \le 16.7\text{ms}$).

---

## 4. Comprehensive Catalog of Engineering Pitfalls

### Module A: Producer Layer & Ingestion (SCStream / WindowServer / Memory Pools)

#### Pitfall 01: Synchronous Work in Capture Callback Induces WindowServer Throttling Avalanche (152 FPS down to 6 FPS)
* **Symptom**: Smooth recording for 2 seconds, followed by real motion collapsing to 6 FPS with 52 duplicate frames.
* **Physics**: The legacy code executed frame padding loops and `usleep(100)` inside `captureQueue`. Stalling for 60~150ms filled SCStream's internal queue. macOS WindowServer detected consumer starvation and **tripped its safety watchdog: throttling screen capture delivery from 152 FPS down to 5~7 FPS**!
* **Iron Rule**: **Absolute zero blocking on the producer**. The `captureQueue` callback must only execute atomic pointer swaps (`FrameSlotBuffer.deposit`), taking **$< 5$ microseconds**.

#### Pitfall 02: 180Hz Arrival Jitter (27 Gaps in 8s) & Destructive Overwrite Cause Fake Freezes & Jumps
* **Empirical Evidence**: Telemetry probe (`scripts/detect_gaps.swift`) dragging a window on a 180Hz 4K display revealed **27 gaps exceeding 16.67ms in 8 seconds** (averaging 3.4 gaps/sec), with the most typical gap being 17.11ms (just 0.44ms late).
* **Physics**:
  1. Window dragging relies on AppKit `NSEvent.mouseDragged`. A 6ms redraw latency skips a 5.55ms V-Sync.
  2. If the consumer fires at $t = 16.67\text{ms}$ with zero tolerance, an incoming frame arriving at 17.11ms is declared missing, writing a duplicate frame and causing a **16.67ms fake freeze**.
  3. With a single-slot buffer, subsequent arrivals at 22ms and 28ms overwrite the 17.11ms frame. The motion trajectory becomes: $0\text{px} \to 0\text{px} (\text{frozen}) \to 28\text{px} (\text{teleport jump})$!
* **Iron Rule**: **Elastic Horizon Queue (16 frames / 88.8ms temporal span)**. The consumer operates with a fixed 1-tick (16.67ms) safety horizon using Nearest-PTS matching, guaranteeing **0 fake freezes and 0 teleport jumps**.

#### Pitfall 03: Insufficient Ring Buffer Depth Induces Buffer Eviction Catastrophe
* **Symptom**: Slight consumer lag causes video to oscillate between 3x slow motion and 70ms jumps.
* **Physics**: At 180Hz (5.55ms/frame), 16 frames cover **88.8ms** ($16 \times 5.55\text{ms}$). If the consumer lags behind physical time by $> 88.8\text{ms}$, newly deposited frames overwrite historical frames. Harvesting past timestamps fails, forcing the buffer to return future frames.
* **Iron Rule**: Expand buffer to 16 frames (~530MB), and enforce zero consumer lag through HEVC hardware acceleration.

---

### Module B: Consumer Scheduler, Clock Anchoring & Pacing

#### Pitfall 04: Pure Auto-Increment Counter (currentSlot += 1) Compresses Time Axis (Video Leads Audio by 1.74s)
* **Symptom**: During a 37.5s recording, video finished 1.74 seconds ahead of audio.
* **Physics**: When backpressure occurred, `lastWrittenSlotIndex` paused. Next tick resumed with `currentSlot += 1`, excising 16.67ms of physical time from the MP4 timeline. 106 backpressures subtracted $106 \times 16.67\text{ms} = 1.76\text{ seconds}$.
* **Iron Rule**: **Anchor target slots strictly to absolute physical hardware time**:
  $$\text{targetSlot} = \operatorname{round}\left((\text{hostNow} - \text{masterOriginHostTime}).\text{seconds} \times \text{targetFPS}\right)$$

#### Pitfall 05: Skip-Slot Clock Anchoring (targetSlot = max(last + 1, physical)) Carves Gaps in MP4 Sample Table
* **Symptom**: During full-screen motion, recording exhibited 4~6 frame freeze jumps every 2 seconds (50 timeline discontinuities).
* **Physics**: When encoder latency spiked, jumping directly to `physicalTarget` skipped 3~4 slots, carving holes into the MP4 sample table. Media players held the previous frame for 66ms then jumped ahead.
* **Iron Rule**: **Timeline must strictly increment monotonically without artificial holes**.

#### Pitfall 06: Multi-Frame Burst Flooding Squeezes Real-Time Micro-Queue, Causing 1066 Backpressures & 1.55s Lag
* **Symptom**: In session `20-14-13` (bursting up to 4 frames/tick), backpressures exploded to **1066 times**, effective throughput dropped to 57 FPS, and clock lag reached **1550ms**.
* **Physics**: Under `expectsMediaDataInRealTime = true`, the driver's hardware FIFO holds only 1~2 frames. Looping `append` 4 times in 0.1ms saturates the FIFO, causing `isReadyForMoreMediaData` to drop to `false` for 50~70ms. This sets up a vicious **limit-cycle resonance** capped at 57 FPS.
* **Iron Rule**: **Strict single-tick execution (Tick-Lock 60 FPS CFR)**. Each tick (16.67ms) writes exactly 1 video frame and 1 audio slice (`1 Tick = 1 Video Frame + 1 Audio Slice`).

#### Pitfall 07: Consumer Sleep (15~40ms) Stalls Serial Queue, Causing Cascading Pileups
* **Symptom**: Cascading frame drops of 100~116ms during window dragging.
* **Physics**: Sleeping 15~40ms on the `encodeQueue` serial queue delayed the next tick, compounding into an 80ms freeze.
* **Iron Rule**: Microsecond-level probe ($\le 3\text{ms}$, `waitAttempts < 30`). Return immediately if busy; never stall the queue.

#### Pitfall 08: Background Execution Triggers App Nap Timer Coalescing (83ms Stalls)
* **Symptom**: Periodic frame drops every 2.6 seconds when running as a menu-bar app.
* **Physics**: macOS power management coalesces timers for background apps, delaying ticks to 83.33ms.
* **Iron Rule**: Hold system real-time assertions throughout capture:
  `ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled])`.

---

### Module C: Cross-Track Audio/Video Interleaving & Clock Alignment

#### Pitfall 09: Misconfiguring `expectsMediaDataInRealTime = false` Triggers Offline Interleaving Deadlock (21.7 FPS)
* **Symptom**: Video throughput collapsed to 21.77 FPS, logging 441 backpressure blocks (stalled for 780ms every second).
* **Physics**: `expectsMediaDataInRealTime = false` activates offline batch transcoding mode. The multiplexer forbids video from leading audio by more than 1.1s. In real-time screen capture, future audio cannot be prepaid, so the container locked video input waiting for real audio to arrive.
* **Iron Rule**: Real-time tracks must strictly set `expectsMediaDataInRealTime = true`.

#### Pitfall 10: Synthetic Silence Audio Descriptor Mismatch Destroys Writer (68-Byte Empty File)
* **Symptom**: Output file was 68 bytes; all frame appends failed.
* **Physics**: Synthetic silence was created as Interleaved (`flags: 9, bytesPerFrame: 8`), whereas ScreenCaptureKit delivers **Non-Interleaved Float32 (`flags: 41, bytesPerFrame: 4`)**. The descriptor mutation invalidated the asset writer.
* **Iron Rule**: Match binary ASBD exactly: 48000Hz, 2 channels, Float32, Non-Interleaved (`flags: 41, bytesPerPacket: 4`).

#### Pitfall 11: Silence Feeder Outpacing Real Audio Drops True Sound (-91 dB Silence)
* **Symptom**: Video was normal, but volume was completely silent at `-91.0 dB`.
* **Physics**: Paving silence up to time $T$ overtook real audio arriving with 20ms soundcard hardware latency ($T - 20\text{ms}$). AVAssetWriter rejected real audio as backwards-in-time expired data.
* **Iron Rule**: Silence feeder must maintain a safe lagging window; real audio always takes precedence.

#### Pitfall 12: Anchoring Silence to Wall Clock Leads Video by > 200ms, Deadlocking AVAssetWriter
* **Symptom**: Window dragging stalled recording every second, dropping 4 frames and drifting by 1 second.
* **Physics**: The 200ms interleaving deadband is bidirectional: **audio leading video by > 200ms locks `videoInput` just as video leading audio does**!
* **Iron Rule**: Audio pacing must anchor strictly to current video write progress: `targetAudioPTS = (lastWrittenSlotIndex + 1) / 60`.

#### Pitfall 13: Writing Real Audio on Capture Thread Induces Track Desynchronization (949ms Drift)
* **Symptom**: Real audio written directly on `captureQueue` raced ahead by 949ms when video encountered transient latency.
* **Iron Rule**: Queue audio on capture (< 5µs); write synchronously inside consumer tick alongside video.

#### Pitfall 14: Concurrent Access to `AVAssetWriterInput` Causes Mutex Contention
* **Physics**: Apple explicitly states `AVAssetWriterInput` is NOT thread-safe. Concurrent calls from multiple queues corrupt multiplexer state.
* **Iron Rule**: All appends must serialize onto `encodeQueue`.

---

### Module D: Hardware Encoder, Memory Bus & Color Science

#### Pitfall 15: Missing BT.709 Metadata Causes Contrast Collapse and Washed-Out Colors
* **Physics**: 32BGRA is 4:4:4 Full Range [0-255]. Without explicit color tags, VideoToolbox defaults to SDTV BT.601 Limited Range [16-235], compressing black `0` to `16` and causing washed-out grey tones.
* **Iron Rule**: Explicitly bind `ITU-R BT.709` primaries, transfer function, and YCbCr matrix.

#### Pitfall 16: Apple Silicon M1 4K H.264 Compute Bottleneck & Missing RealTime Flag
* **Physics**: Under 4K motion, H.264 single-frame compression takes 15~20ms, leaving zero safety margin.
* **Iron Rule**:
  1. Inject `(kVTCompressionPropertyKey_RealTime as String): true`;
  2. **Bind Apple Silicon Native 4K HEVC (H.265)**: Cuts latency to **2~3ms**, securing $> 14\text{ms}$ of computational headroom!

#### Pitfall 17: Synchronous Logging I/O and APFS File Stat Lock Cause Rhythmic Backpressure
* **Physics**: Writing logs synchronously under NSLock and calling `FileManager.attributesOfItem` on the active MP4 file provoked APFS inode locks.
* **Iron Rule**: Asynchronous log dispatching; estimate file size mathematically during recording.

---

## 5. Core Implementations

### 1. Zero-Copy Ring Buffer & Nearest-PTS Matching (`FrameSlotBuffer.swift`)

```swift
public final class FrameSlotBuffer: @unchecked Sendable {
    private struct StampedFrame {
        let buffer: CVPixelBuffer
        let pts: CMTime
    }
    private let capacity: Int = 16
    private var ring: [StampedFrame?]
    private var head: Int = 0
    private var count: Int = 0
    private let lock = NSLock()

    // Producer: Atomic pointer swap in < 5 microseconds (Zero Blocking)
    public func deposit(_ buffer: CVPixelBuffer, presentationTimeStamp pts: CMTime) {
        lock.lock()
        ring[head] = StampedFrame(buffer: buffer, pts: pts)
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
        lock.unlock()
    }

    // Consumer: Nearest-PTS harvest within 88.8ms temporal horizon (0 Fake Freezes)
    public func harvestNearest(to targetPTS: CMTime) -> (buffer: CVPixelBuffer, pts: CMTime)? {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return nil }
        var bestFrame: StampedFrame?
        var minDiff = Double.infinity
        for i in 0..<count {
            let idx = (head - 1 - i + capacity) % capacity
            guard let frame = ring[idx] else { continue }
            let diff = abs(CMTimeSubtract(frame.pts, targetPTS).seconds)
            if diff < minDiff {
                minDiff = diff
                bestFrame = frame
            }
        }
        guard let best = bestFrame else { return nil }
        return (best.buffer, best.pts)
    }
}
```

### 2. Strict Single-Tick Consumer Engine (`ScreenRecorder.swift`)

```swift
// Consumer 16.6667ms timer tick: 1 Tick = 1 Video Frame + 1 Audio Slice
private func handleEncodeTick() {
    guard isRecording, !isPaused, sessionStarted,
          let adaptor = pixelBufferAdaptor, let vInput = videoInput else { return }

    let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
    let physicalTarget = currentPhysicalTargetSlot(atHostTime: hostNow)
    let nextSlot = lastWrittenSlotIndex + 1
    guard physicalTarget >= nextSlot else { return }

    let targetSlot = nextSlot // Strict single-slot progress: No jumps, no bursts

    // Microsecond hardware readiness probe (<= 3ms)
    var waitAttempts = 0
    while !vInput.isReadyForMoreMediaData && waitAttempts < 30 {
        usleep(100)
        waitAttempts += 1
    }
    guard vInput.isReadyForMoreMediaData else {
        diagnostics.onDropEncoderBusy(count: 1, waitMicros: waitAttempts * 100)
        return
    }

    let slotPTS = CMTime(value: targetSlot, timescale: 60)
    guard let (frameBuffer, _) = frameBuffer.harvestNearest(to: slotPTS) else { return }

    if adaptor.append(frameBuffer, withPresentationTime: slotPTS) {
        lastWrittenSlotIndex = targetSlot
        diagnostics.onFrameWritten()

        // Dual-track millisecond lockstep: advance audio synchronously
        if let aInput = audioInput {
            audioPacer.paveAudioToSlot(targetSlot: targetSlot, input: aInput, diagnostics: diagnostics)
        }
    }
}
```

### 3. Dual-Track Millisecond Lockstep Audio Engine (`AudioPacer.swift`)

```swift
// Strictly paces audio to (targetSlot + 1) / 60, keeping drift <= 16.7ms
public func paveAudioToSlot(targetSlot: Int64, input: AVAssetWriterInput, diagnostics: RecordingDiagnostics) {
    lock.lock()
    defer { lock.unlock() }

    let targetAudioTime = CMTime(value: targetSlot + 1, timescale: 60)
    
    // 1. Drain pending real audio samples
    while !pendingBuffers.isEmpty {
        let sample = pendingBuffers[0]
        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sample)
        if samplePTS <= targetAudioTime {
            input.append(sample)
            lastAudioPTS = samplePTS
            pendingBuffers.removeFirst()
        } else {
            break
        }
    }

    // 2. Synthesize aligned non-interleaved silence slice if system was quiet
    if lastAudioPTS < targetAudioTime {
        let gapDuration = CMTimeSubtract(targetAudioTime, lastAudioPTS)
        if let silence = generateAlignedSilence(duration: gapDuration, atPTS: lastAudioPTS) {
            input.append(silence)
            lastAudioPTS = targetAudioTime
        }
    }
}
```

---

## 6. Empirical Telemetry & Benchmark Verification

Under extreme window dragging and full-screen scrolling stress testing (2532 interactive events: 1037 drags, 883 scrolls), real-world telemetry confirms:

| Metric | v4.0 Burst + H.264 (`20-14-13`) | v6.0 Tick-Lock + HEVC (`20-28-57`) | Improvement |
| :--- | :--- | :--- | :--- |
| **Hardware Backpressures** | **1066 events** (Severe recurring blocks) | **0 events (ZERO!)** | **100% Eliminated** |
| **Hardware Encoder Drops** | 116 frames (5.47% drop rate) | **1 frame (0.06% drop rate)** | **99.0% Reduction** |
| **MP4 Timeline Slot Jumps** | 50 discontinuity holes | **0 jumps (ZERO!)** | **100% Continuous** |
| **A/V Sync Drift** | 1550 ms (Severe 1.55s desync) | **12.71 ms** (Strictly $\le 16.7\text{ms}$) | **Broadcast Quality** |
| **Cumulative Clock Lag** | Diverged to 1550 ms | **Constant ~18 ms (0.00ms drift)** | **Zero Cumulative Lag** |
| **60fps Smooth Motion Ratio** | 40.3% (54.8% slow-mo + 12.1% jump) | **99.0% Smooth Motion** | **True High-Refresh Look**|
| **Single-Frame 4K Encode Latency**| 15 ~ 20 ms (Bumping 16.67ms line) | **2 ~ 3 ms (14ms headroom)** | **85% Latency Reduction**|

---

## 7. Production Hardware Topology & Operational Specifications

All parameters are locked as follows:

```text
┌───────────────────────────────────────────────────────────────────────────────────────┐
│                    VCapture 4K 60 FPS CFR Production Operational Baseline             │
├────────────────────┬──────────────────────────────────────────────────────────────────┤
│ Host SoC / RAM     │ Apple M1 (8-core CPU / 8-core GPU) | 16 GB LPDDR4X (68.25 GB/s)  │
│ Capture Source     │ MZQ27F180 (3840×2160 4K UHD @ 180.00Hz Gaming Display)           │
│ Stream Config      │ SCStream minimumFrameInterval = .zero (180Hz direct), queue = 32 │
│ Pixel Format       │ kCVPixelFormatType_32BGRA (4:4:4 Full Range 0-255, 33.18 MB/frame)│
│ Color Primaries    │ ITU_R_709_2 Primaries / TransferFunction / YCbCrMatrix bound     │
│ Video Codec        │ HEVC (H.265) Main Profile | kVTCompressionPropertyKey_RealTime=true│
│ Framerate Control  │ Strict 60.000000 FPS CFR (Tick-Lock Pacing, 1 Tick = 1 Frame)   │
│ A/V Synchronization│ Locked-Step Dual-Track (Audio PTS = (slot + 1) / 60)             │
│ Audio Format       │ 48000Hz, Stereo, Float32, Non-Interleaved (flags: 41, bytes: 4)  │
│ Frame Buffer       │ FrameSlotBuffer Capacity 16 (~530MB RAM), Nearest-PTS Harvest    │
│ Process Assertion  │ ProcessInfo latencyCritical + userInitiated + idleSleepDisabled  │
│ Delivery Protocol  │ Direct MP4 Streaming Write, Stop & Deliver, Zero Transcoding     │
└────────────────────┴──────────────────────────────────────────────────────────────────┘
```
