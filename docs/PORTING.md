# 当前基线与平台差异

重新读取远程仓库后，以以下版本为基线实现：

- `ddyec/AGY-PC` main: `c802423`，beta.10 消息底部产物与图片预览；同时读取 beta.7–9 的摘要、队列、即时引导、网络、技能与布局改动。
- `ddyec/Agy-iPhone` main: `ab0f1d7`，读取其原生文件引用、设置隔离、SSE、会话及账号逻辑。Live Activities / Dynamic Island 是 iPhone 特性，未伪造 Mac 对应功能。
- 网关仍使用现有 `/v1` 协议，本次没有修改或重启生产服务器，没有发起模型任务。

| 功能 | Intel Mac 实现 |
| --- | --- |
| 会话、历史、模型与思考强度 | 动态 API；原生侧栏及独立选择器 |
| Restriction/Turbo、执行模式 | 独立设置；只审批当前操作 |
| 文件/图片上传、产物下载、整个文件夹 @ | AppKit 文件选择与 SwiftUI 文件浏览；保留原始路径、展示相对标签 |
| 消息底部产物、图片预览 | 认证下载缓存、ImageIO 缩略图、缩放预览 |
| 思考摘要与输出模式 | 原版、工具折叠摘要、结论优先 |
| 队列和立即引导 | 持久队列；立即引导先等停止完成；未知发送状态保留原请求号 |
| 设置记忆与账号隔离 | Keychain + AES-GCM；按 origin/accountProfile 隔离 |
| 技能/工作流 | 插入提示词、引用 SKILL.md；不声称服务端支持未启用能力 |
| DoH | 使用 Apple Network PrivacyContext 原生 RFC 8484，非 PC 手写 socket 解析；系统/Private Relay 规则保留 |
| 代理 | 系统代理、直连、显式 HTTP 或 SOCKS5；不接受带密码的代理 URL |
| 混合构建 | 本机 Intel zsh 与服务器 AGY；不显示 Windows 或 WSL |
| 项目同步 | 新目录、限制大小、拒绝路径穿越/链接/大小写与 Unicode 冲突；解压过程校验长度及 CRC |

Mac 构建命令按用户确认执行。停止操作会尽力终止当时发现的子进程与启动命令，独立脱离父进程运行的守护程序不由此管理。项目快照由网关生成；该协议不保证保留原工程的可执行权限，需要时用 `bash build.sh` 或在本机按项目说明设置权限。

首版未提供自动更新、Developer ID 公证、无人值守远程构建调度或托管 Docker/虚拟机。不会自动改变系统网络、安装容器或修改服务器账号。

Apple 加密 DNS 的系统优先级说明：[PrivacyContext](https://developer.apple.com/documentation/network/nwparameters/privacycontext/requireencryptednameresolution(_:fallbackresolver:))、[WWDC20](https://developer.apple.com/videos/play/wwdc2020/10047/)。
