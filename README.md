# AGY · Mac — Intel 版

面向 **Intel x86_64 Mac，macOS 13 及以上**，包括 macOS 26 Tahoe。界面使用 SwiftUI / AppKit，连接现有 AGY HTTPS 网关；Google 登录继续由服务器上的 AGY 管理。

## 下载与运行

从 [Releases](https://github.com/ddyec/AGY-Mac/releases) 下载 **Intel-Builder.zip**，完整解压后双击 **Build-Intel.command**。

这是**本机构建包**：它会在你的 Intel Mac 上编译原生应用，验证产物只有 x86_64，生成 `.app` 和运行 ZIP，然后打开 Finder 并启动。此仓库初版没有在 Linux 上伪造 macOS 二进制；最终原生编译需由 Mac 完成。没有使用 GitHub Actions。

需要 Apple Command Line Tools。尚未安装时脚本会打开 Apple 安装入口，安装完成后重新双击即可；也可以先执行：

```bash
xcode-select --install
```

如果 Finder 不允许直接运行下载的脚本，在“终端”输入 `/bin/bash `（末尾保留空格），把 `Build-Intel.command` 拖进窗口再按回车；不需要关闭 Gatekeeper。

构建输出在 `~/Library/Application Support/AGY-Mac/Builds/Intel-.../`，包括 `AGY-Mac.app`、Intel 运行包、`build.log` 和构建报告。SDK 编译缓存会复用。你可以把生成的 `.app` 拖到“应用程序”文件夹；脚本不会覆盖已安装的应用。

首次连接填写与 iPhone / PC 相同的 **HTTPS 服务器地址和连接密钥**，不是 Google 密码。密钥存储在 macOS 钥匙串。草稿、设置、队列与待确认消息使用 AES-GCM 加密，密钥也在钥匙串中；不同服务器账号分别保存。

## 已实现

- 原生侧栏、搜索、会话切换、重命名与删除；主题跟随系统，也可选择浅色/深色。
- 聊天历史与 SSE 实时消息、代码块换行/复制、思考摘要、工具折叠、结论优先；长对话分批加载，用户向上阅读时停止跟随。
- 服务器动态模型列表，先选模型，再选思考强度；Restriction/Turbo 审批与“先做计划/直接实施”分开设置。
- 原生文件选择、拖放上传、文件浏览、下载产物、`@` 文件和整个文件夹。手机/电脑看到相对名称，实际请求保留服务器的完整引用路径。单文件 25 MB、单条最多 8 个引用。
- 消息底部集中显示产物；图片缩略图、放大/缩小预览与下载。图片和文件通过已认证的会话接口读取，不把密钥传给第三方图片地址。
- 运行中的消息加入队列；也可“立即引导”先停止当前任务再发送。发送结果不明时保存原编号，先核对，或由用户明确按原编号重试。
- 读取真实额度并显示进度；快捷工作流、自定义技能、发现项目 `.agents/skills` / `.agent/skills` 中的 `SKILL.md`。快捷工作流只是插入待确认的输入，执行能力由实际 AGY 版本决定。
- 原生 DoH 与系统/HTTP/SOCKS5 代理设置。默认跟随系统 DNS；启用 DoH 后不静默降级为明文 DNS。系统既有加密 DNS 或 Private Relay 可能优先。
- Intel Mac 本机构建与服务器构建分开；服务器项目同步到新本机副本，执行前展示位置和命令，按需回传日志与产物。Mac 版没有 WSL 入口。

模型、额度、文件范围与审批能力以当前服务器响应为准；客户端不会编造模型、额度或执行结果。

## 开发

```bash
swift test
swift build -c release --arch x86_64 --product AGY-Mac
/bin/bash scripts/build-intel.sh
```

`Sources/AGYMacCore` 包含可在 Linux 验证的协议、账号隔离、草稿/待确认发送、队列、SSE、文件引用与快照逻辑。`Sources/AGYMacApp` 是真正的 macOS 原生界面，只在 macOS 分支编译。Linux 构建出的同名命令只会提示不支持 GUI，不会被打包成 Mac 应用。

初版基线为 AGY-PC `c802423`（beta.10）及 AGY-iPhone `ab0f1d7`。移植差异见 [功能对照](docs/PORTING.md)，实际验证边界见 [VALIDATION.md](VALIDATION.md)。
