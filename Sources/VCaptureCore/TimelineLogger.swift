import Foundation
import CoreMedia

/// 负责将每一帧的槽位、硬件时间戳与运动状态逐帧写入 CSV 时间轴文件
/// 保证分析音画同步与帧率稳定性时拥有微秒级精度物理依据
public final class TimelineLogger: @unchecked Sendable {
    private let fileURL: URL
    private let targetFPS: Int
    private var fileHandle: FileHandle?
    private var lastRecordedPTSMs: Double = 0.0
    private var lastHostTimeMs: Double = 0.0
    private let writeQueue = DispatchQueue(label: "com.freevian.vcapture.timeline-logger", qos: .utility)

    public init(fileURL: URL, targetFPS: Int) {
        self.fileURL = fileURL
        self.targetFPS = targetFPS

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)

        let header = "slot_index,pts_seconds,pts_ms,delta_pts_ms,host_elapsed_ms,delta_host_ms,source_time_ms,source_diff_ms,is_real_motion,status\n"
        if let data = header.data(using: .utf8) {
            self.fileHandle?.write(data)
        }
    }

    /// 记录槽位帧事件
    /// - Parameters:
    ///   - slot: CFR 目标槽位号 (0, 1, 2...)
    ///   - hostElapsedMs: 相对视频录制起点的物理经过时间 (毫秒)
    ///   - sourceTimeMs: 提取的源端硬件时间戳 (毫秒，静态帧为 -1.0)
    ///   - sourceDiffMs: 源端时间戳与槽位理想时间戳偏差 (毫秒)
    ///   - isRealMotion: 是否为渲染交付的真实动效帧 (若为 false 则为静止补齐帧)
    ///   - status: 帧状态标记 (FIRST_FRAME, REAL, PADDING_GAP, STATIC_HEARTBEAT, STOP_DRAIN)
    public func logSlot(slot: Int64, hostElapsedMs: Double, sourceTimeMs: Double = -1.0, sourceDiffMs: Double = 0.0, isRealMotion: Bool, status: String) {
        let ptsSec = Double(slot) / Double(targetFPS)
        let ptsMs = ptsSec * 1000.0
        let deltaPTS = lastRecordedPTSMs > 0 ? (ptsMs - lastRecordedPTSMs) : (1000.0 / Double(targetFPS))
        let deltaHost = lastHostTimeMs > 0 ? (hostElapsedMs - lastHostTimeMs) : 0.0

        lastRecordedPTSMs = ptsMs
        if isRealMotion {
            lastHostTimeMs = hostElapsedMs
        }

        let line = String(
            format: "%lld,%.6f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%@\n",
            slot, ptsSec, ptsMs, deltaPTS, hostElapsedMs, deltaHost, sourceTimeMs, sourceDiffMs, isRealMotion ? 1 : 0, status
        )

        writeQueue.async { [weak self] in
            guard let self = self, let data = line.data(using: .utf8) else { return }
            self.fileHandle?.write(data)
        }
    }

    /// 录制完成时同步刷新并关闭文件
    public func finish() {
        writeQueue.sync {
            try? self.fileHandle?.synchronize()
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }
}
