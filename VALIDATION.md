# 验证记录与边界

## 已实际执行

- Swift 6.0.3 / Linux ARM64 编译共享 `AGYMacCore` 与 C/zlib 边界层。
- **18 项核心测试通过**：HTTPS origin、请求头凭据隔离、重定向/502 拒绝、模型和强度、完整文件夹引用、UTF-8/CRLF/BOM SSE、加密持久化失败保留、账号隔离、未知发送状态、显式重试原请求号、队列/即时引导、快照路径与 Unicode 冲突、压缩/二进制提取。
- 使用 Swift 编译器 `-frontend -parse -target x86_64-apple-macosx13.0` 解析全部实际 macOS UI 分支，不使用假的 SwiftUI 类型或替代界面。
- Bash 构建脚本语法、Info.plist 配置、包内源码哈希、可执行权限与排除密钥检查。
- 以 Mac 客户端 User-Agent 对现有网关 `/v1/status` 做一次只读验证：HTTP 200、协议 1、文件浏览能力存在。未打印密钥、未发送模型任务、未改服务器。

模拟 HTTP 传输的状态机测试关闭后台观察任务，避免 Linux URLProtocol 在取消模拟流时死锁；SSE 字节帧独立测试。真实 Apple URLSession 流、后台自动出队及取消行为仍需要 Mac 集成验证。

## 必须在 Mac 完成

本服务器没有 macOS SDK，也没有运行 macOS 26 Tahoe。**SwiftUI/AppKit 的完整类型编译、链接、钥匙串/AES 运行、加密 DNS、原生窗口显示、Finder 文件选择和本机构建的端到端验收尚未完成。** 语法解析及 Linux 核心编译不能替代这些步骤。

Release 提供源码和 Intel 本机构建入口，不将 Linux ELF、语法检查结果或中间对象伪装成 `.app`。`Build-Intel.command` 在实际 Intel Mac 上编译、检查 Mach-O 架构、组装图标和应用、ad-hoc 签名并生成运行 ZIP；成功构建报告明确保留视觉验收未完成标志。

没有创建 GitHub Actions 工作流，没有使用 Actions。首版没有 Developer ID 签名或公证，不宣称已通过 Gatekeeper 分发验收。
