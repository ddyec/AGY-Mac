# AGY · Mac — Intel 版

面向 **Intel x86_64 Mac，macOS 13 及以上**，包括 macOS 26 Tahoe。界面使用 SwiftUI / AppKit，连接现有 AGY HTTPS 网关；Google 登录继续由服务器上的 AGY 管理。

## 下载与运行

在 [Releases](https://github.com/ddyec/AGY-Mac/releases) 下载 **macos-x86_64.zip**，完整解压后把 `AGY-Mac.app` 放到“应用程序”并打开。运行包由 GitHub Actions 的 **macOS 26 Intel** 机器真实编译，主程序仅包含 x86_64；最低部署目标为 macOS 13。

应用使用 ad-hoc 签名，尚无 Developer ID 公证。若 macOS 拦截下载应用，可在系统“隐私与安全性”中允许打开这个应用；无需关闭系统安全机制。也可下载 **Intel-Builder.zip** 在自己的 Intel Mac 上双击 `Build-Intel.command`，使用 Apple Command Line Tools 构建，源码包同样提供。

本机构建输出在 `~/Library/Application Support/AGY-Mac/Builds/Intel-.../`，不会覆盖已安装的版本。缺少 Apple Command Line Tools 时脚本会打开安装入口；完成后重新运行即可。

首次连接填写与 iPhone / PC 相同的 **HTTPS 服务器地址和连接密钥**，不是 Google 密码。密钥存储在 macOS 钥匙串。草稿、设置、队列与待确认消息使用 AES-GCM 加密，密钥也在钥匙串中；不同服务器账号分别保存。

## 原生界面检查

用户授权后新增手动运行的 Intel Tahoe Actions：原生编译、18 项测试、应用启动与 18 个离线场景取图。预览不读取钥匙串、不连接生产服务器；这部分使用明确标注的示例数据。

CI 的 WindowServer 抓屏不可用时，使用已显示窗口的 AppKit `cacheDisplay` 绘制取图，捕获方式记录在 `capture-manifest.json`。图片来自实际 SwiftUI/AppKit 视图；系统玻璃、窗口阴影等效果可能与桌面抓屏不同。源码和截图结果都不会把自动取图等同于完整交互验收。

人工查看首轮图片后，修正了空白侧栏呈现、深色顶栏白块、重复页标题和缺失输入提示。后续截图与记录见 [界面检查记录](docs/UI_REVIEW.md)。

## 已实现

- 原生侧栏、搜索、会话切换、重命名与删除；主题跟随系统，也可选择浅色/深色。
- 聊天历史与 SSE 实时消息、代码块换行/复制、思考摘要、工具折叠、结论优先；长对话分批加载，用户向上阅读时停止跟随。
- 服务器动态模型列表，先选模型，再选思考强度；Restriction/Turbo 审批与“先做计划/直接实施”分开设置。
- 原生文件选择、拖放上传、文件浏览、下载产物、`@` 文件和整个文件夹。手机/电脑看到相对名称，实际请求保留服务器的完整引用路径。单文件 25 MB、单条最多 8 个引用。
- 消息底部集中显示产物；图片缩略图、放大/缩小预览与下载。图片和文件通过已认证的会话接口读取，不把密钥传给第三方图片地址。
- 运行中的消息加入队列；也可“立即引导”先停止当前任务再发送。发送结果不明时保存原编号，先核对，或由用户明确按原编号重试。
- 读取真实额度并显示进度；快捷工作流、自定义技能、发现项目 `.agents/skills` / `.agent/skills` 中的 `SKILL.md`。快捷工作流只是插入待确认的输入，执行能力由实际 AGY 版本决定。
- 原生 DoH 与系统/HTTP/SOCKS5 代理设置。默认跟随系统 DNS；启用 DoH 后不静默降级为明文 DNS。系统既有加密 DNS 或 Private Relay 可能优先。
- AI 自动混合构建：发送任务前探测并注册 Intel Mac 工具链。AI 通过原生终端工具查询设备、按项目目标调用 Mac，自动同步新副本，运行命令并回传退出码、日志及产物；AI 可据此修复后继续构建。网页/Linux 任务用服务器原生工具。Restriction 审批展示实际 Mac 命令，Turbo 直接执行。Mac 版没有 WSL 入口。

模型、额度、文件范围与审批能力以当前服务器响应为准；客户端不会编造模型、额度或执行结果。

## 开发

```bash
swift test
swift build -c release --arch x86_64 --product AGY-Mac
/bin/bash scripts/build-intel.sh
```

`Sources/AGYMacCore` 包含可在 Linux 验证的协议、账号隔离、草稿/待确认发送、队列、SSE、文件引用与快照逻辑。`Sources/AGYMacApp` 是真正的 macOS 原生界面，只在 macOS 分支编译。Linux 构建出的同名命令只会提示不支持 GUI，不会被打包成 Mac 应用。

初版基线为 AGY-PC `c802423`（beta.10）及 AGY-iPhone `ab0f1d7`。移植差异见 [功能对照](docs/PORTING.md)，实际验证边界见 [VALIDATION.md](VALIDATION.md)。

## AI 自动混合构建（beta.3）

保持 Mac 应用运行并联网，正常在对话中提出任务即可。例如“把这个 SwiftUI 项目编译成 Intel Mac 应用，失败就修到通过，把运行包发给我”。客户端在发送前自动注册当前会话的设备能力；不需要去构建页点击执行。构建页现在以自动运行状态为主，手动命令收进高级诊断区。允许 AI 本机构建的设置按服务器账号保存，默认开启，可随时暂停。

服务端必须同时升级为本仓库的 `Server/gateway.py`，仍可兼容原 iPhone / PC 协议。继续使用原有 `--data`、`--profile-home`、`--key-file`、`--root` 和 `--agy` 参数，不迁移或复制 Google 凭据。见 [自动构建设计与部署](docs/AI_BUILDS.md)。旧服务器会明确显示需要升级，不会冒充已经自动执行。
