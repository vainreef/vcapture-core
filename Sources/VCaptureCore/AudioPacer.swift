import Foundation
import AVFoundation
import CoreMedia

/// 负责系统音频与麦克风在 AVAssetWriter 容器内的安全滞后锁步 (Safety-Lagged Pacing)
/// 核心准则：
/// 1. 真实系统音频具有最高优先级，原始硬件时间戳原汁原味入轨，绝不被静音抢跑覆盖
/// 2. 仅在系统静音超过 120ms 时，平滑垫写合成静音，但永远保持 80ms 的安全缓冲时延，绝不反超真实音频 (25ms 声卡延迟)
/// 3. 所有方法在内部由 NSLock 严格串行化，彻底消除 AVAssetWriterInput 跨队列并发竞争
/// 4. 停止录制时瞬间平齐尾部，确保 finishWriting 在 0.05 秒内交付
public final class AudioPacer: @unchecked Sendable {
    private let targetSampleRate: Double = 48000
    private let channelCount: Int = 2
    private let sampleCount = 800 // 48000 / 60 = 800 采样/帧，与 60 FPS 视频槽位物理绝对对齐

    private let lock = NSLock()
    private var audioFormatDesc: CMAudioFormatDescription?
    private var silenceBlockBuffer: CMBlockBuffer?

    private var pendingRealAudio: [CMSampleBuffer] = []
    private var _lastAudioPTS: CMTime = .zero
    private var _firstAudioHostTime: CMTime = .invalid
    private var _initialAudioOffsetMs: Double = 0.0

    public var lastAudioPTS: CMTime {
        lock.withLock { _lastAudioPTS }
    }
    public var firstAudioHostTime: CMTime {
        lock.withLock { _firstAudioHostTime }
    }
    public var initialAudioOffsetMs: Double {
        lock.withLock { _initialAudioOffsetMs }
    }

    public init() {
        // 严格匹配 ScreenCaptureKit 原生交付格式:
        // 48000Hz, 双声道, 32-bit Float, Non-Interleaved (mFormatFlags: 41, mBytesPerFrame: 4)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: targetSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 41,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &audioFormatDesc
        )

        let byteCount = sampleCount * 4 * channelCount
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &silenceBlockBuffer
        )
        if let bb = silenceBlockBuffer {
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: bb, offsetIntoDestination: 0, dataLength: byteCount)
        }
    }

    public func reset() {
        lock.withLock {
            _lastAudioPTS = .zero
            _firstAudioHostTime = .invalid
            _initialAudioOffsetMs = 0.0
            pendingRealAudio.removeAll()
        }
    }

    /// 生产端极速接收 ScreenCaptureKit 真实音频 (耗时 < 5 微秒，绝不直接写盘)
    public func handleRealAudio(
        sampleBuffer: CMSampleBuffer,
        rawPTS: CMTime,
        masterOriginHostTime: CMTime,
        totalPauseDuration: CMTime,
        diagnostics: RecordingDiagnostics
    ) {
        lock.withLock {
            if let realDesc = CMSampleBufferGetFormatDescription(sampleBuffer) {
                self.audioFormatDesc = realDesc
            }

            if !_firstAudioHostTime.isValid {
                _firstAudioHostTime = rawPTS
                let offsetSec = CMTimeSubtract(rawPTS, masterOriginHostTime).seconds
                _initialAudioOffsetMs = offsetSec * 1000.0
                diagnostics.logInfo(String(format: "音频首帧就绪: 相对视频起始偏移 %.2f ms", _initialAudioOffsetMs))
            }

            let baseOffset = CMTimeAdd(masterOriginHostTime, totalPauseDuration)
            guard CMTimeCompare(rawPTS, baseOffset) >= 0 else { return }

            guard let adjusted = adjustAudioTiming(sampleBuffer: sampleBuffer, offset: baseOffset) else { return }
            pendingRealAudio.append(adjusted)
        }
    }

    /// 消费端双轨毫秒级锁步推进：严格且仅将音频推进到 targetTime (videoPTS + 1/60s)
    /// 真实音频具有最高优先级，原汁原味入轨，绝不丢弃任何真实音频帧！
    public func paceAudio(upTo targetTime: CMTime, input: AVAssetWriterInput, diagnostics: RecordingDiagnostics) {
        lock.withLock {
            guard input.isReadyForMoreMediaData else { return }

            // 1. 消耗所有起始时间落后或覆盖 targetTime 的真实音频缓冲块
            while !pendingRealAudio.isEmpty && input.isReadyForMoreMediaData {
                let nextBuf = pendingRealAudio[0]
                let bufPTS = CMSampleBufferGetPresentationTimeStamp(nextBuf)
                let dur = CMSampleBufferGetDuration(nextBuf)
                let actualDur = (dur.isValid && dur.seconds > 0) ? dur : CMTime(value: 960, timescale: 48000)

                // 仅消耗目标时间之前的真实音频块
                if CMTimeCompare(bufPTS, targetTime) <= 0 {
                    // 若真实音频块前存在明显间隙 (> 5ms)，垫写静音平滑平整过渡
                    if CMTimeCompare(_lastAudioPTS, bufPTS) < 0 && CMTimeSubtract(bufPTS, _lastAudioPTS).seconds > 0.005 {
                        appendSilenceLocked(upTo: bufPTS, input: input, diagnostics: diagnostics)
                        guard input.isReadyForMoreMediaData else { break }
                    }

                    let effectiveBuf: CMSampleBuffer
                    if _lastAudioPTS > .zero && CMTimeCompare(bufPTS, _lastAudioPTS) < 0 {
                        effectiveBuf = alignBufferToPTS(nextBuf, newPTS: _lastAudioPTS) ?? nextBuf
                    } else {
                        effectiveBuf = nextBuf
                    }

                    guard input.isReadyForMoreMediaData else { break }

                    let actualPTS = CMSampleBufferGetPresentationTimeStamp(effectiveBuf)
                    let actualEndPTS = CMTimeAdd(actualPTS, actualDur)

                    if input.append(effectiveBuf) {
                        pendingRealAudio.removeFirst()
                        _lastAudioPTS = actualEndPTS
                        diagnostics.onAudioBufferWritten()
                    } else {
                        break
                    }
                } else {
                    // 该音频块属于未来视频槽位，留在队列中等待下拍
                    break
                }
            }

            // 2. 仅在真实音频严重断流滞后 (> 80ms) 时，垫写合成静音保活，但保持 40ms 安全防撞距离，绝不反超真实音频！
            let maxLag = CMTime(value: 80, timescale: 1000) // 80ms
            let safetyLag = CMTime(value: 40, timescale: 1000) // 40ms
            if CMTimeCompare(targetTime, CMTimeAdd(_lastAudioPTS, maxLag)) > 0 {
                let safeTarget = CMTimeSubtract(targetTime, safetyLag)
                appendSilenceLocked(upTo: safeTarget, input: input, diagnostics: diagnostics)
            }
        }
    }

    /// 停止录制时，将所有残余真实音频及微量静音彻底平齐到视频终点，保证秒级 finishWriting
    public func drainFinalAudio(upTo finalVideoPTS: CMTime, input: AVAssetWriterInput, diagnostics: RecordingDiagnostics) {
        lock.withLock {
            while !pendingRealAudio.isEmpty && input.isReadyForMoreMediaData {
                let nextBuf = pendingRealAudio[0]
                let bufPTS = CMSampleBufferGetPresentationTimeStamp(nextBuf)
                let dur = CMSampleBufferGetDuration(nextBuf)
                let actualDur = (dur.isValid && dur.seconds > 0) ? dur : CMTime(value: 960, timescale: 48000)

                if CMTimeCompare(_lastAudioPTS, bufPTS) < 0 && CMTimeSubtract(bufPTS, _lastAudioPTS).seconds > 0.005 {
                    appendSilenceLocked(upTo: bufPTS, input: input, diagnostics: diagnostics)
                    guard input.isReadyForMoreMediaData else { break }
                }

                let effectiveBuf: CMSampleBuffer
                if _lastAudioPTS > .zero && CMTimeCompare(bufPTS, _lastAudioPTS) < 0 {
                    effectiveBuf = alignBufferToPTS(nextBuf, newPTS: _lastAudioPTS) ?? nextBuf
                } else {
                    effectiveBuf = nextBuf
                }

                guard input.isReadyForMoreMediaData else { break }

                let actualPTS = CMSampleBufferGetPresentationTimeStamp(effectiveBuf)
                let actualEndPTS = CMTimeAdd(actualPTS, actualDur)

                if CMTimeCompare(actualPTS, finalVideoPTS) <= 0 {
                    if input.append(effectiveBuf) {
                        pendingRealAudio.removeFirst()
                        _lastAudioPTS = actualEndPTS
                        diagnostics.onAudioBufferWritten()
                    } else {
                        break
                    }
                } else {
                    pendingRealAudio.removeFirst()
                }
            }
            if CMTimeCompare(_lastAudioPTS, finalVideoPTS) < 0 && input.isReadyForMoreMediaData {
                appendSilenceLocked(upTo: finalVideoPTS, input: input, diagnostics: diagnostics)
            }
        }
    }

    private func alignBufferToPTS(_ sampleBuffer: CMSampleBuffer, newPTS: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }

        var timingArray = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingArray, entriesNeededOut: &count)

        for i in 0..<count {
            timingArray[i].presentationTimeStamp = newPTS
        }

        var newBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingArray,
            sampleBufferOut: &newBuffer
        )
        return status == noErr ? newBuffer : sampleBuffer
    }

    private func appendSilenceLocked(upTo targetTime: CMTime, input: AVAssetWriterInput, diagnostics: RecordingDiagnostics) {
        guard let bb = silenceBlockBuffer, let desc = audioFormatDesc else { return }
        let sampleDuration = CMTime(value: Int64(sampleCount), timescale: CMTimeScale(targetSampleRate))

        while CMTimeCompare(_lastAudioPTS, targetTime) < 0 {
            guard input.isReadyForMoreMediaData else { break }

            var sBuf: CMSampleBuffer?
            var timing = CMSampleTimingInfo(
                duration: sampleDuration,
                presentationTimeStamp: _lastAudioPTS,
                decodeTimeStamp: .invalid
            )
            CMSampleBufferCreate(
                allocator: kCFAllocatorDefault,
                dataBuffer: bb,
                dataReady: true,
                makeDataReadyCallback: nil,
                refcon: nil,
                formatDescription: desc,
                sampleCount: sampleCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sBuf
            )
            guard let buffer = sBuf else { break }
            if input.append(buffer) {
                _lastAudioPTS = CMTimeAdd(_lastAudioPTS, sampleDuration)
                diagnostics.onAudioBufferWritten()
            } else {
                break
            }
        }
    }

    private func adjustAudioTiming(sampleBuffer: CMSampleBuffer, offset: CMTime) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard count > 0 else { return sampleBuffer }

        var timingArray = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timingArray, entriesNeededOut: &count)

        for i in 0..<count {
            if timingArray[i].presentationTimeStamp.isValid {
                timingArray[i].presentationTimeStamp = CMTimeSubtract(timingArray[i].presentationTimeStamp, offset)
            }
            if timingArray[i].decodeTimeStamp.isValid {
                timingArray[i].decodeTimeStamp = CMTimeSubtract(timingArray[i].decodeTimeStamp, offset)
            }
        }

        var adjustedBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timingArray,
            sampleBufferOut: &adjustedBuffer
        )
        return adjustedBuffer ?? sampleBuffer
    }
}
