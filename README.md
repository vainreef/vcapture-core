# VCaptureCore

[English Version](README-en.md) | [中文说明](README.md) | [深度工程白皮书 (中文)](ENGINEERING-DEEP-DIVE-zh.md) | [Engineering Whitepaper (EN)](ENGINEERING-DEEP-DIVE-en.md)

---

### 💡 这是干什么的？具体解决了什么问题？（不用术语的通俗说明）

如果你在开发 macOS 屏幕录制功能，只要你调用了苹果官方的 **ScreenCaptureKit** 和 **AVAssetWriter**，你就**一定会**遇到以下这几个让人抓狂的现实问题：

1. **高刷屏掉帧卡顿**：在 120Hz / 144Hz / 180Hz 高刷屏上（比如 MacBook Pro 自带屏或外接电竞屏），只要鼠标拖动窗口或者快速滚屏，录出来的视频就会明显发卡、掉帧、甚至每隔几秒就莫名其妙定格一下；
2. **音画越来越不同步**：录制时间稍长，画面和声音就对不上了，最后画面比声音快了一两秒，或者声音超前画面；
3. **录制器卡死或文件损坏**：点击停止录制时卡死很久，或者系统一段时间没声音后突然有声音，导致录制器直接崩溃，生成只有几十字节的损坏废文件；
4. **画面发灰偏色**：录出来的 4K 视频黑色发灰、对比度塌陷，颜色明显不如屏幕原本显示的鲜艳；
5. **硬件编码报错丢帧**：日志里频繁报底层硬件堵塞（`isReadyForMoreMediaData == false`），导致一秒钟丢掉几十帧。

👉 **这个仓库分享的就是彻底解决上述所有问题的核心逻辑代码。**  
它能让你直接在 **4K 超高清、180Hz 极端高刷、疯狂拖窗滚屏** 的严苛场景下，录出**严格 60 帧恒定帧率、毫秒级音画同步、颜色 100% 还原、零卡顿零丢帧**的高品质视频。

---

### 🤖 想要使用？直接交给 AI Agent 搞定！

**你不需要自己一行行死磕复杂的音视频底层细节：**  
直接 `git clone` 这个仓库，然后**把你日常使用的 AI Coding Agent（如 Cursor / Claude Code / Antigravity / Windsurf 等）直接丢进本仓库文件夹，让 AI Agent 阅读并分析里面的代码与白皮书**。  
AI Agent 能够立刻理解这套生产者-消费者解耦、环形抗抖动池、单拍恒速推进和双轨锁步逻辑，并无缝将这套核心管线移植到你自己的项目中！

---

## 🎯 核心解决的问题与技术指标

在传统录屏实现中，高刷 4K 拖窗或滚屏常引发严重的音画脱节、每秒数十次硬件反压与剧烈顿挫。VCaptureCore 实现了以下严苛的工业级指标：

| 关键技术指标 | 传统实现 / 经验方案 | VCaptureCore 闭环表现 |
| :--- | :--- | :--- |
| **分辨率与色彩** | 经常降采样为 1080p 或 NV12 偏色 | **原生 4K (3840×2160) @ 32BGRA 全动态范围 4:4:4** |
| **帧率模型** | 可变帧率 (VFR) 导致剪辑音画错位 | **严格 60.000000 FPS CFR (恒定帧率)**，逐帧间隔恒定 16.6667ms |
| **硬件反压堵塞** | 4 帧并发倾泻产生 **1066 次** 反压挂起 | **0 次 (ZERO 反压)**，消除底层微队列共振 |
| **硬件丢帧率** | 复杂运动时掉帧率 5.47% (116 帧) | **0.06% (实测 30 秒仅 1 帧)** |
| **时间轴连续性** | 产生 50 处跳槽断崖，画面定格瞬移 | **0 次跳槽空洞**，时间轴 100% 平滑连续 |
| **音画同步偏差** | 声音与画面脱节 1.55 ~ 1.74 秒 | **恒定 12.71 ms** (严格处于广播级 $\le 16.7\text{ms}$ 极窄锁步区间) |
| **交付机制** | 需漫长二次转码合并 | **停止即交付 (Stop & Deliver)**，直接流式写盘，零二次转码 |

---

## 🏗️ 核心架构与五大底层创新

```text
  [1. 生产端: SCStream 180Hz 全速捕获]
     └─► minimumFrameInterval = .zero (每 5.55ms 交付一帧)
     └─► deposit() ──► 原子指针交换 (耗时 < 5µs，生产端绝对零阻塞)

  [2. 显存池: 16 帧弹性抗抖动环形队列 (Elastic Horizon Queue)]
     └─► 深度 16 帧 (~530MB 显存)，跨度 88.8ms
     └─► Nearest-PTS 最近邻时间戳匹配 (解决 AppKit 拖拽 0.44ms 微抖动，0 假静止误判)

  [3. 消费端: 严格单拍恒速推进引擎 (Tick-Lock 60 FPS CFR)]
     └─► DispatchSourceTimer 准点 16.6667ms 唤醒
     └─► 1 Tick = 1 Video Frame + 1 Audio Slice (严禁单拍循环突发倾泻)
     └─► 微秒级极速窥探 (<= 3ms)，绝不长睡眠霸占队列

  [4. 编码通道: Apple Silicon 原生 4K HEVC 硬件加速]
     └─► 绑定 AVVideoCodecType.hevc (M 系列芯片专有矩阵加速)
     └─► 4K 单帧编码耗时仅 2~3ms (比 H.264 的 18ms 节省 85% 算力，留足 >14ms 裕量)
     └─► 全链路硬绑定 ITU-R BT.709 原生色彩元数据

  [5. 双轨推进: 音视频毫秒级绝对锁步 (AudioPacer)]
     └─► 真实音频在消费端伴随视频写入，进度锁定至 targetAudioPTS = (slot + 1) / 60
     └─► 二进制格式对齐 (48kHz, Non-Interleaved Float32)
     └─► 彻底杜绝 AVAssetWriter 200ms 双向跨轨交织硬锁死
```

---

## 📦 模块组成

| 文件 | 职责说明 |
| :--- | :--- |
| `FrameSlotBuffer.swift` | 显存零拷贝环形缓冲池（深度 16 帧），提供 Nearest-PTS 最近邻弹性时间戳提取。 |
| `AudioPacer.swift` | 双轨毫秒级锁步伴随音频推进器，合成非交错静音切片，杜绝交织死锁。 |
| `ScreenRecorder.swift` | 核心录制驱动管线（解耦生产与消费端、HEVC 硬件配置、Tick-Lock 60fps 调度器）。 |
| `RecordingConfig.swift` | 录制分辨率、帧率预设与硬件偶数对齐计算。 |
| `RecordingDiagnostics.swift` | 纳秒级异步性能与遥测计数器（反压、掉帧、帧率统计）。 |
| `TimelineLogger.swift` | 逐帧微秒级时间轴 CSV 记录器（提供 CFR 间隔与时钟漂移实证）。 |
| `SourceStreamTracker.swift` | 生产端原始帧到达时钟记录器。 |

---

## 🚀 快速上手 (Swift Package Manager)

### 1. 引入依赖
在项目的 `Package.swift` 中引入本子仓库：

```swift
dependencies: [
    .package(path: "../VCaptureCore") // 或远端 Git 仓库地址
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["VCaptureCore"]
    )
]
```

### 2. 基础使用示例

```swift
import VCaptureCore
import CoreGraphics

// 1. 初始化录制配置
var config = RecordingConfig(
    selectedDisplayID: CGMainDisplayID(),
    resolution: .native,    // 保持 4K 原生分辨率
    frameRate: .fps60,      // 严格 60 FPS CFR
    captureSystemAudio: true
)

// 2. 创建核心录制器实例
let outputURL = URL(fileURLWithPath: "/path/to/output/video.mp4")
let recorder = ScreenRecorder(config: config, outputURL: outputURL)

// 3. 启动录制 (异步)
Task {
    do {
        try await recorder.startCapture()
        print("Screen recording started smoothly at 60 FPS CFR.")
        
        // 运行录制...
        try await Task.sleep(nanoseconds: 10_000_000_000)
        
        // 4. 停止录制并交付 (直接完成 MP4 写盘，零二次转码)
        try await recorder.stopCapture()
        print("Recording saved to \(outputURL.path)")
    } catch {
        print("Capture failed: \(error)")
    }
}
```

---

## 📖 深度工程文档

关于这套管线在 27 处技术陷阱（如 WindowServer 降频看门狗、实时微队列 FIFO 饱和、88.8ms 环形池时序冲刷失效、200ms 双向交织死锁等）中的深度物理推导与调试记录，请参阅：
- [完整工程深度剖析白皮书 (中文版)](ENGINEERING-DEEP-DIVE-zh.md)
- [Complete Engineering Deep Dive Whitepaper (English)](ENGINEERING-DEEP-DIVE-en.md)

---

## 📄 开源许可证

MIT License.
