# AGY for Mac (Intel)

面向 **Intel Mac（x86_64，macOS 13+，兼容 macOS 26 Tahoe）** 的 SwiftUI / AppKit 原生 Antigravity 客户端。

连接现有的 AGY HTTPS 网关，提供原生 macOS 聊天窗口、文件管理，以及 **AI 自动混合构建**能力——让服务器上的 AI 直接调用你本机的 Mac 工具链编译和调试 Apple 平台项目。

---

## 主要功能

- **原生 macOS 界面体验**：
  - 采用 SwiftUI 与 AppKit 构建，包含原生侧边栏、会话搜索、深浅色主题切换、两阶段思考过程摘要、工具折叠与文件改动抽屉。
  - 输入框基于原生 AppKit 定制，完整支持中文输入法候选框定位、剪贴板直接粘贴图片、拖拽上传附件，以及 `Enter` / `Cmd+Enter` 快捷发送。
  - 消息底部集中展示生成产物，支持图片缩略图、缩放预览与一键下载。
- **AI 自动混合构建（Auto Hybrid Build）**：
  - 保持 Mac 客户端在线时，向 AI 提出 macOS / iOS 构建任务（例如“把这个 SwiftUI 项目编译成 Mac 应用，有报错就修到通过为止”），客户端会自动向当前会话注册本机编译环境。
  - AI 会自动将服务器项目快照同步到 Mac 本机独立目录、执行 Xcode / Swift 编译命令，并自动读取返回的退出码、构建日志与产物来继续修复代码，无需手动点击构建面板。
- **文件管理与 `@` 引用**：
  - 直接浏览远程工作区文件、上传本地文件、下载构建产物。
  - 输入 `@` 即可引用单个文件或整个文件夹，支持单条消息引用多个路径。
- **消息队列与引导**：
  - 任务运行期间发送新消息可自动加入等待队列，也可选择“立即引导”中断当前步骤并立即插入新指令。
- **安全与网络设置**：
  - 连接密钥保存在 macOS **钥匙串（Keychain）** 中；本地草稿、设置与待发送队列均使用 **AES-GCM** 加密存储，多服务器账号相互隔离。
  - 内置 **DoH（加密 DNS）** 与系统 / HTTP / SOCKS5 代理配置。

---

## 下载与安装

1. 前往 [Releases](https://github.com/ddyec/AGY-Mac/releases) 下载 `macos-x86_64.zip`。
2. 解压后将 `AGY-Mac.app` 拖入“应用程序”文件夹并打开。
3. **首次打开提示**：由于应用采用 ad-hoc 签名、未进行 Apple Developer ID 公证，若首次启动被系统拦截，请前往“**系统设置 → 隐私与安全性**”底部点击“仍要打开”即可（无需关闭系统 SIP 或 Gatekeeper）。
4. 启动后输入与 iPhone / PC 端相同的 **HTTPS 服务器地址和连接密钥**即可连接。

---

## 本地编译与开发

如果你希望在自己的 Intel Mac 上从源码编译，只需安装 Apple Command Line Tools 或 Xcode，然后双击 `Build-Intel.command`，或在终端执行：

```bash
# 运行核心单元测试
swift test

# 编译并打包原生 Mac 应用
/bin/bash scripts/build-intel.sh
```

打包完成的应用默认输出在 `~/Library/Application Support/AGY-Mac/Builds/` 目录下，不会覆盖你正在使用的版本。

---

## 配套网关与相关文档

要使用 **AI 自动混合构建**功能，服务端需运行本仓库 `Server/gateway.py` 提供的网关版本（完全向后兼容 iPhone 与 PC 客户端，沿用原有的启动参数与账号目录）。

- [AI 自动混合构建设计与部署说明](docs/AI_BUILDS.md)
- [跨平台功能移植对照](docs/PORTING.md)
- [原生界面截图预览](docs/UI_REVIEW.md)
- [验证记录](docs/VALIDATION.md)
