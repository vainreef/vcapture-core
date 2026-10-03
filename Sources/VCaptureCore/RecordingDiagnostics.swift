import Foundation
import os.log

public final class RecordingDiagnostics: @unchecked Sendable {
    private let logFileURL: URL
    private let bundleDiagnosticsURL: URL?
    private let fileHandle: FileHandle?
    private var bundleFileHandle: FileHandle?
    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.freevian.vcapture", category: "Performance")
    private let writeQueue = DispatchQueue(label: "com.freevian.vcapture.diagnostics-write", qos: .utility)

    // 累积统计指标
    public private(set) var sckFramesDelivered: Int64 = 0
    public private(set) var realFramesWritten: Int64 = 0
    public private(set) var paddingFramesWritten: Int64 = 0
    public private(set) var surplusFramesSkipped: Int64 = 0
    public private(set) var droppedEncoderBusy: Int64 = 0
    public private(set) var droppedAdaptorFailed: Int64 = 0
    public private(set) var audioBuffersWritten: Int64 = 0

    // 源端时序与停顿指标
    public private(set) var sourceGapsOver25ms: Int = 0
    public private(set) var sourceGapsOver33ms: Int = 0
    public private(set) var sourceGapsOver50ms: Int = 0
    public private(set) var maxSourceGapMs: Double = 0.0
    private var lastSCKHostTime: CFAbsoluteTime = 0

    // 硬件编码器延迟指标
    public private(set) var totalEncoderWaitMicros: Int64 = 0
    public private(set) var maxEncoderWaitMicros: Int = 0

    // 每秒周期监控指标
    private var lastIntervalTime: CFAbsoluteTime = 0
    private var intervalSCK: Int64 = 0
    private var intervalReal: Int64 = 0
    private var intervalPadded: Int64 = 0
    private var intervalSkipped: Int64 = 0
    private var intervalDropped: Int64 = 0
    private var intervalAudio: Int64 = 0

    private var startTime: CFAbsoluteTime = 0
    private let targetFPS: Int

    public init(targetFPS: Int, bundleDiagnosticsURL: URL? = nil) {
        self.targetFPS = targetFPS
        self.bundleDiagnosticsURL = bundleDiagnosticsURL

        let logsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/VCapture", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        let fileURL = logsDir.appendingPathComponent("recording.log")
        self.logFileURL = fileURL

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        self.fileHandle?.seekToEndOfFile()

        if let bundleURL = bundleDiagnosticsURL {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
            }
            FileManager.default.createFile(atPath: bundleURL.path, contents: nil)
            self.bundleFileHandle = try? FileHandle(forWritingTo: bundleURL)
        }
    }

    public func start(details: String = "") {
        lock.lock()
        defer { lock.unlock() }

        startTime = CFAbsoluteTimeGetCurrent()
        lastIntervalTime = startTime
        lastSCKHostTime = startTime

        sckFramesDelivered = 0
        realFramesWritten = 0
        paddingFramesWritten = 0
        surplusFramesSkipped = 0
        droppedEncoderBusy = 0
        droppedAdaptorFailed = 0
        audioBuffersWritten = 0
        sourceGapsOver25ms = 0
        sourceGapsOver33ms = 0
        sourceGapsOver50ms = 0
        maxSourceGapMs = 0.0
        totalEncoderWaitMicros = 0
        maxEncoderWaitMicros = 0

        intervalSCK = 0
        intervalReal = 0
        intervalPadded = 0
        intervalSkipped = 0
        intervalDropped = 0
        intervalAudio = 0

        var header = "\n=== [VCapture 录制会话启动: \(ISO8601DateFormatter().string(from: Date())) | 目标: \(targetFPS) FPS CFR] ===\n"
        if !details.isEmpty {
            header += "[环境参数] \(details)\n"
        }
        writeLog(header)
    }

    public func logInfo(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        writeLog("[INFO] \(message)\n")
    }

    public func onSCKFrameReceived() {
        lock.lock()
        defer { lock.unlock() }

        let now = CFAbsoluteTimeGetCurrent()
        if lastSCKHostTime > 0 {
            let deltaMs = (now - lastSCKHostTime) * 1000.0
            if deltaMs > 25.0 { sourceGapsOver25ms += 1 }
            if deltaMs > 33.3 { sourceGapsOver33ms += 1 }
            if deltaMs > 50.0 { sourceGapsOver50ms += 1 }
            if deltaMs > maxSourceGapMs { maxSourceGapMs = deltaMs }
        }
        lastSCKHostTime = now

        sckFramesDelivered += 1
        intervalSCK += 1
    }

    public func onRealFrameWritten(waitMicros: Int = 0) {
        lock.lock()
        defer { lock.unlock() }

        realFramesWritten += 1
        intervalReal += 1
        totalEncoderWaitMicros += Int64(waitMicros)
        if waitMicros > maxEncoderWaitMicros {
            maxEncoderWaitMicros = waitMicros
        }
        checkIntervalTick()
    }

    public func onPaddingFrameWritten(count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }

        paddingFramesWritten += Int64(count)
        intervalPadded += Int64(count)
        checkIntervalTick()
    }

    public func onSurplusFrameSkipped(count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }

        surplusFramesSkipped += Int64(count)
        intervalSkipped += Int64(count)
    }

    public func onDropEncoderBusy(count: Int = 1, waitMicros: Int = 0) {
        lock.lock()
        defer { lock.unlock() }

        droppedEncoderBusy += Int64(count)
        intervalDropped += Int64(count)
        totalEncoderWaitMicros += Int64(waitMicros)

        if intervalDropped == 1 {
            let warn = "⚠️ [BACKPRESSURE] 硬件编码器瞬时反压 (等待 \(waitMicros)µs)，由内存弹性缓冲顺次追赶！\n"
            writeLog(warn)
        }
        checkIntervalTick()
    }

    public func onDropAdaptorFailed(error: Error? = nil) {
        lock.lock()
        defer { lock.unlock() }

        droppedAdaptorFailed += 1
        intervalDropped += 1
        var warn = "⚠️ [DROP ALERT] AVAssetWriterInputPixelBufferAdaptor 追加失败！"
        if let err = error {
            warn += " 原因: \(err.localizedDescription)\n"
        } else {
            warn += "\n"
        }
        writeLog(warn)
        checkIntervalTick()
    }

    public func onAudioBufferWritten() {
        lock.lock()
        defer { lock.unlock() }

        audioBuffersWritten += 1
        intervalAudio += 1
    }

    private func checkIntervalTick() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsedSinceLast = now - lastIntervalTime
        if elapsedSinceLast >= 1.0 {
            let totalElapsed = now - startTime
            let fpsCurrent = Double(intervalReal + intervalPadded) / elapsedSinceLast
            let avgWaitMs = intervalReal > 0 ? Double(totalEncoderWaitMicros) / Double(realFramesWritten) / 1000.0 : 0.0

            let line = String(
                format: "[VCapture 性能 %4.1fs] SCK交付: %3d fps (过滤高刷: %3d) | 写入: %2d (动效: %2d, 补齐: %2d) | 反压: %d | 编码耗时: %.2fms | 音频: %2d 块 | 瞬时帧率: %.1f FPS\n",
                totalElapsed, intervalSCK, intervalSkipped, intervalReal + intervalPadded, intervalReal, intervalPadded, intervalDropped, avgWaitMs, intervalAudio, fpsCurrent
            )
            writeLog(line)

            intervalSCK = 0
            intervalReal = 0
            intervalPadded = 0
            intervalSkipped = 0
            intervalDropped = 0
            intervalAudio = 0
            lastIntervalTime = now
        }
    }

    public func finish(durationSeconds: Double, audioDuration: Double = 0.0, initialAudioOffsetMs: Double = 0.0) -> String {
        lock.lock()
        defer { lock.unlock() }

        let totalWritten = realFramesWritten + paddingFramesWritten
        let expectedSlots = Int64(round(durationSeconds * Double(targetFPS)))
        let actualDropped = max(0, expectedSlots - totalWritten) + droppedAdaptorFailed
        let dropRate = expectedSlots > 0 ? (Double(actualDropped) / Double(expectedSlots)) * 100.0 : 0.0
        let realRatio = totalWritten > 0 ? (Double(realFramesWritten) / Double(totalWritten)) * 100.0 : 0.0
        let padRatio = totalWritten > 0 ? (Double(paddingFramesWritten) / Double(totalWritten)) * 100.0 : 0.0
        let actualFPS = durationSeconds > 0 ? Double(totalWritten) / durationSeconds : 0.0
        let avgEncoderWaitMs = realFramesWritten > 0 ? Double(totalEncoderWaitMicros) / Double(realFramesWritten) / 1000.0 : 0.0
        let avDriftMs = abs(durationSeconds - audioDuration) * 1000.0

        let report = """
        ==================== VCapture 性能与音画同步诊断报告 ====================
        【视频管线】
        录制总时长: \(String(format: "%.3f", durationSeconds)) 秒 (目标: \(targetFPS) FPS 恒定帧率 CFR)
        实际写入总帧数: \(totalWritten) 帧 (有效帧率: \(String(format: "%.2f", actualFPS)) FPS)
          ├─ 真实渲染动效帧: \(realFramesWritten) 帧 (占比 \(String(format: "%.1f", realRatio))%)
          ├─ 静止填补重复帧: \(paddingFramesWritten) 帧 (占比 \(String(format: "%.1f", padRatio))%)
          └─ 硬件编码掉帧数: \(actualDropped) 帧 (掉帧率: \(String(format: "%.2f", dropRate))%)
        SCStream 物理交付总帧数: \(sckFramesDelivered) 帧 (平滑过滤多余高刷: \(surplusFramesSkipped) 帧)
        源端轻微停顿 (>25ms): \(sourceGapsOver25ms) 次
        源端明显停顿 (>33ms): \(sourceGapsOver33ms) 次
        源端严重停顿 (>50ms): \(sourceGapsOver50ms) 次
        源端最大单次停顿: \(String(format: "%.1f", maxSourceGapMs)) ms

        【硬件编码器性能】
        编码器反压暂缓次数 (isReady == false): \(droppedEncoderBusy) 次
        编码器单帧平均等待耗时: \(String(format: "%.2f", avgEncoderWaitMs)) ms
        编码器单帧最大等待耗时: \(String(format: "%.2f", Double(maxEncoderWaitMicros) / 1000.0)) ms
        适配器追加失败次数: \(droppedAdaptorFailed) 次

        【音画同步指标】
        系统音频采样块数: \(audioBuffersWritten) 块
        音频总时长: \(String(format: "%.3f", audioDuration)) 秒
        音画起始偏移 (Initial Offset): \(String(format: "%.2f", initialAudioOffsetMs)) ms
        音画总时长漂移 (A/V Drift): \(String(format: "%.2f", avDriftMs)) ms
        ====================================================================
        """
        writeLog(report + "\n")
        writeQueue.sync {
            try? self.fileHandle?.synchronize()
            try? self.bundleFileHandle?.synchronize()
            try? self.bundleFileHandle?.close()
            self.bundleFileHandle = nil
        }

        return report
    }

    private func writeLog(_ text: String) {
        print(text, terminator: "")
        logger.info("\(text, privacy: .public)")
        guard let data = text.data(using: .utf8) else { return }
        writeQueue.async { [weak self] in
            guard let self = self else { return }
            self.fileHandle?.write(data)
            self.bundleFileHandle?.write(data)
        }
    }

    deinit {
        try? fileHandle?.close()
        try? bundleFileHandle?.close()
    }
}
