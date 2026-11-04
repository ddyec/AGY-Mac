# Native macOS Actions 与视觉检查

按用户本次明确授权，已新增 `macos-26-intel` 手动 Actions，覆盖真实 Apple SDK 编译、20 项核心测试、Intel Mach-O 校验、应用组装与签名，以及实际窗口启动。不能再用此前 Linux-only 的记录代表当前状态。

## 已实际发现并修复

- SwiftUI `@State` / Combine `@Published` 多变量声明造成的语义编译错误；拆分为独立属性。
- 原生 DoH API 的 bootstrap 参数需要 `[NWEndpoint]`；按实际 SDK 类型修正。
- 仅依赖自动场景启动时没有创建窗口；改为 AppKit 明确创建 `NSWindow` 和 `NSHostingController`，提供原生菜单与关闭行为。
- runner 的 WindowServer 屏幕捕获失败；改用窗口自身 AppKit 渲染并记录捕获方法。
- 人工查看首轮原生渲染图，发现侧栏/玻璃区域未呈现、深色顶栏白块、重复标题及缺失输入提示；调整为明确的原生分栏与背景、统一内容顶栏，并补提示。

18 个场景涵盖登录、欢迎页、聊天、模型弹窗、文件、构建、设置、技能的浅/深色，以及窄窗口和审批/队列。所有场景使用离线假数据与内存状态，不读取真实凭据；生产网关和账号未改动。

## 验证边界

实际验证环境为 Intel macOS 26；macOS 13 为部署目标，未在 macOS 13 实机运行。界面快照为 AppKit 窗口渲染，不是 WindowServer 桌面抓屏。钥匙串真实登录、用户网络下的 DoH/代理、实际审批任务、长时 SSE/后台出队及真实本机工程构建仍需用户环境验证。

应用为 ad-hoc 签名，未做 Developer ID 公证。Actions 成功、18 项测试通过及截图人工检查不等于所有交互均已验收。

历史 Linux 核心测试还覆盖快照边界、账号隔离和未知发送状态；HTTP 模拟测试关闭背景观察任务，SSE 字节帧单独验证。

## beta.3 自动构建验证

新增 31 项 Python 网关测试（含 8 项 AI 构建调度测试），以及 Intel Actions 上生产 HybridWorker 的真实进程执行测试。该离线测试验证自动领取、快照解压、Intel 执行、日志与产物回传，不把模拟 AGY 调度等同于真实模型决策验收。
