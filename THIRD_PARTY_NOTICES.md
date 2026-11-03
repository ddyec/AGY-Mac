# 品牌与第三方说明

AGY · Mac 是独立客户端，不代表 Google 或 Apple。

Antigravity 名称及全彩图标属于 Google。`Brand/Mark.png` 复用 AGY-PC 已有的官方品牌原图，不是重新绘制的图标：

- https://antigravity.google/press
- https://antigravity.google/assets/image/brand/antigravity-icon__full-color.png

应用使用 macOS 自带的 SwiftUI、AppKit、Network、Security、CryptoKit 与系统 zlib，没有第三方 Swift Package 依赖。`Sources/CArchive` 为本项目编写的小型系统 zlib 接口，不附带 zlib 源码或单独再分发其动态库。

本机构建可能由 Apple 的 swift-stdlib-tool 复制所需 Swift 运行时兼容库；其许可见 Swift 项目 [LICENSE](https://github.com/swiftlang/swift/blob/main/LICENSE.txt)（Apache 2.0 with Runtime Library Exception）及构建所用 Apple SDK 的相应许可。本仓库和源码包不附带 Apple SDK 或 Linux Swift 工具链。
