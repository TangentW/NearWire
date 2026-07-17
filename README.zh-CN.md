[English](README.md)

<div align="center">
  <h1>NearWire</h1>
  <p><strong>在 iOS App 与 Mac 之间，建立一条直接的事件通道。</strong></p>
  <p>不需要服务端，不需要账号，也不依赖 USB 连接。</p>
</div>

NearWire 是一个面向 iOS 开发的本地优先、双向事件平台。App 接入 Swift SDK，Mac 打开原生 Viewer，输入对频码后，两端即可通过加密的近距离网络连接交换结构化事件。

它适合那些普通日志不够用的场景：实时观察 App 状态、跟踪复杂业务流程、从 Mac 向设备发送调试指令，或者同时查看多个 App 的性能变化。

<p align="center">
  <img src="Documentation/Assets/nearwire-viewer-events.jpg" alt="NearWire Viewer 的事件时间线和 JSON 检查器，内容为演示数据" width="100%">
  <br>
  <sub>原生 macOS Viewer · 事件时间线、搜索过滤和结构化 JSON 查看 · 演示数据</sub>
</p>

## 为什么做 NearWire

### 默认就是本地直连

iOS App 直接连接 Mac Viewer。Bonjour 负责发现附近的 Viewer，Apple 平台可以建立近距离链路时会使用支持点对点的网络能力，TLS 1.3 则负责加密传输。团队不需要部署服务端，也不需要配置账号体系。

### 传递事件，而不只是文本日志

每个消息都包含事件类型和 Codable JSON 内容。这份简单的约定可以承载页面跳转、网络请求摘要、状态快照、功能开关、诊断命令，或者团队自己的业务调试数据。

### 从一开始就支持双向通信

App 可以向 Viewer 发送事件，Viewer 也可以向 App 发送事件。因此 NearWire 不只是一个观察工具，也可以作为轻量的开发控制通道。

### 生命周期清晰，资源消耗可控

`NearWire` 是实例，不是单例。连接、断开、缓存、性能采样和可选 UI 都由接入方明确控制。队列容量、速率、TTL 和“只保留最新值”策略都有边界，避免高频事件无限堆积。

## 整体结构

| iOS App | 近距离加密链路 | macOS Viewer |
| --- | :---: | --- |
| 接入 `NearWire` SDK | Bonjour 自动发现 | 打开后立即监听 |
| 收发 Codable 事件 | TLS 1.3 | 查看、搜索和过滤事件 |
| 可选发送性能快照 | 双向通信 | 向 App 发送控制事件 |
| 一个 App 同时连接一个 Viewer | ⇄ | 一个 Viewer 可连接多个 App |

六位对频码用于选择附近广播的 Viewer。它不会持久化，切换 Mac 时可以随时更换。对频码是发现和匹配标识，不是密码，也不是证书凭据。

## 快速接入

### 1. 添加 SDK

通过 Swift Package Manager 添加：

```text
https://github.com/TangentW/NearWire.git
```

然后把 `NearWire` Product 链接到 iOS Target。只有在需要时，再额外引入 `NearWireUI` 或 `NearWirePerformance`。

通过 CocoaPods 接入：

```ruby
pod "NearWire"

# 可选能力
pod "NearWire/UI"
pod "NearWire/Performance"
```

NearWire 支持 iOS 16+、macOS 13+、Xcode 16+，并使用 Swift 5 语言模式。

### 2. 连接并发送事件

在 Mac 上打开 NearWire Viewer，把 Viewer 显示的对频码输入 App：

```swift
import NearWire

struct CheckoutSnapshot: Codable, Sendable {
  let orderID: String
  let itemCount: Int
  let total: Decimal
}

let nearWire = NearWire()

try await nearWire.connect(code: "N7K4PX")

_ = try await nearWire.send(
  type: "checkout.snapshot",
  content: CheckoutSnapshot(
    orderID: "order_7F31",
    itemCount: 3,
    total: 268
  )
)
```

还未连接时也可以先发送事件，事件会进入有容量上限的内存队列。单个事件编码后的 JSON 内容最大支持 1 MiB。

### 3. 接收 Viewer 发来的事件

```swift
struct FeatureFlagOverride: Codable, Sendable {
  let name: String
  let enabled: Bool
}

for try await event in nearWire.events {
  guard event.type == "feature.flag.override" else { continue }

  let override = try event.decode(FeatureFlagOverride.self)
  await featureFlags.apply(override)
}
```

下行事件通过 `AsyncThrowingStream` 提供；连接状态和详细状态也使用现代 Swift 异步序列进行观察。

## 可选能力

### 可直接使用的 SDK 面板

可选的 SwiftUI 面板可以同时提供连接控制、性能采集开关，以及 Viewer 最新发送给 App
的一条事件：

```swift
import NearWire
import NearWireUI
import NearWirePerformance

let nearWire = NearWire()
let performanceMonitor = NearWirePerformanceMonitor(nearWire: nearWire)

NearWirePanelView(
  nearWire: nearWire,
  performanceMonitor: performanceMonitor
)
```

面板本身不会自动连接，也不会自动开始性能采集；这两个实例及其生命周期仍由 App
管理。如果需要自定义布局，也可以分别使用 `NearWireConnectionView`、
`NearWirePerformanceControlView` 和 `NearWireLatestViewerEventView`。最新事件视图使用独立且有
容量边界的订阅，不会抢走 App 业务代码收到的事件。

### 内建性能快照

可选性能模块也可以完全通过代码控制，并通过同一条事件通道发送聚合后的设备和 App
性能数据：

```swift
import NearWirePerformance

let monitor = NearWirePerformanceMonitor(nearWire: nearWire)
try await monitor.start()
```

只有接入方主动调用后才会开始采样。Viewer 会在独立的性能窗口中展示和分析这些数据。

<p align="center">
  <img src="Documentation/Assets/nearwire-viewer-performance.png" alt="使用演示数据的 NearWire 性能看板" width="100%">
  <br>
  <sub>独立性能窗口 · 帧率、CPU、内存、电量和发热状态 · 演示数据</sub>
</p>

## 设计边界

- NearWire 是开发阶段的实时事件通道，不是线上监控服务。
- 传输默认加密，但当前对频码不会验证一个预先受信任的 Viewer 身份。
- `send` 成功表示事件进入了本地发送流程，不代表 Viewer 已经完成端到端确认。
- 离线缓存只存在于内存中，App 进程退出后不会保留。
- NearWire 不会暗中接管 App 生命周期，也不会自行决定后台运行策略。

这些边界让 SDK 保持小巧、行为明确，并且在 App 不需要它时容易移除。

## 继续体验

- 运行维护中的 [Demo App](Demo/README.md)，可以完整体验连接 UI、双向事件、队列诊断和性能采样。
- 需要查询完整公开 API、分发方式、传输或协议细节时，再进入 [Documentation](Documentation)。

NearWire 使用 [MIT License](LICENSE) 开源。
