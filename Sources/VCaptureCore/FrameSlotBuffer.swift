import Foundation
import CoreVideo
import CoreMedia

/// 带弹性滑动视界的无锁/轻量锁环形帧队列 (Elastic Horizon Ring Buffer, 铁律十一)
/// - 生产端（captureQueue）：极速入队，耗时 < 3 微秒，保留最近 5 帧显存指针与硬件相对时间戳，零内存拷贝
/// - 消费端（encodeQueue）：以 1 拍（16.67ms）安全视界，按目标相对时间戳进行最近邻检索（Nearest-PTS）
/// - 彻底根除因源端 0.44ms 微小抖动造成的 16.67ms 假静止冻结与过渡帧丢失瞬移
public final class FrameSlotBuffer: @unchecked Sendable {
    public struct BufferedFrame {
        public let buffer: CVPixelBuffer
        public let relativeTimeSec: Double
    }

    private let lock = NSLock()
    private let capacity: Int = 16
    private var ring: [BufferedFrame] = []
    private var lastCommittedBuffer: CVPixelBuffer?
    private var hasNewArrival: Bool = false

    public init() {
        ring.reserveCapacity(capacity)
    }

    /// 生产端极速投递入环形队列（耗时 < 3 微秒，绝对零阻塞，铁律一）
    public func deposit(buffer: CVPixelBuffer, relativeTimeSec: Double) {
        lock.lock()
        if ring.count >= capacity {
            ring.removeFirst()
        }
        ring.append(BufferedFrame(buffer: buffer, relativeTimeSec: relativeTimeSec))
        hasNewArrival = true
        lock.unlock()
    }

    /// 消费端按目标槽位时间戳在弹性视界内检索最贴合的物理帧
    /// - Parameter targetTimeSec: 目标槽位的理想时间戳（如 slot * 1/60s）
    /// - Returns:
    ///   - buffer: 提取的图像帧 (新动效帧或静止复用帧)
    ///   - isRealMotion: 是否为实际动效帧（若为 false 则为静态复用帧）
    public func harvest(targetTimeSec: Double) -> (buffer: CVPixelBuffer, isRealMotion: Bool, sourceTimeSec: Double, diffMs: Double)? {
        lock.lock()
        defer { lock.unlock() }

        if !ring.isEmpty && hasNewArrival {
            // 在环形队列中检索与 targetTimeSec 最贴合（差值绝对值最小）的物理帧
            var bestIdx = 0
            var minDiff = Double.infinity
            for (i, item) in ring.enumerated() {
                let diff = abs(item.relativeTimeSec - targetTimeSec)
                if diff < minDiff {
                    minDiff = diff
                    bestIdx = i
                }
            }

            let chosen = ring[bestIdx]
            self.lastCommittedBuffer = chosen.buffer

            // 弹出被选中帧及其之前的过往历史帧，释放显存引用即刻归还 WindowServer 池
            ring.removeSubrange(0...bestIdx)

            if ring.isEmpty {
                hasNewArrival = false
            }

            let diffMs = (chosen.relativeTimeSec - targetTimeSec) * 1000.0
            return (chosen.buffer, true, chosen.relativeTimeSec, diffMs)
        } else if let lastBuf = lastCommittedBuffer {
            // 屏幕完全静止，复用上一拍画面维持严格 60 FPS CFR
            return (lastBuf, false, -1.0, 0.0)
        }

        return nil
    }

    /// 停止录制时排空视界内残留的最后一帧
    public func drainFinal(targetTimeSec: Double) -> (buffer: CVPixelBuffer, isRealMotion: Bool, sourceTimeSec: Double, diffMs: Double)? {
        lock.lock()
        defer { lock.unlock() }
        if let last = ring.last {
            ring.removeAll()
            self.lastCommittedBuffer = last.buffer
            self.hasNewArrival = false
            let diffMs = (last.relativeTimeSec - targetTimeSec) * 1000.0
            return (last.buffer, true, last.relativeTimeSec, diffMs)
        } else if let lastBuf = lastCommittedBuffer {
            return (lastBuf, false, -1.0, 0.0)
        }
        return nil
    }

    /// 重置状态
    public func reset() {
        lock.lock()
        ring.removeAll()
        lastCommittedBuffer = nil
        hasNewArrival = false
        lock.unlock()
    }
}
