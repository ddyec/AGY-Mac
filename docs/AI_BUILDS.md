# AI 自动混合构建

## 用户操作

打开 Mac 应用连接服务器，在聊天中提出任务即可。无需填写本机目录或构建命令；AI 根据用户目标、项目清单和在线工具选择环境。SwiftUI/Xcode/Apple 目标调用在线 Mac；网页和 Linux 使用服务器终端。通用 Swift/CMake/Cargo 项目仍按实际目标判断。选择计划模式时，AI 先规划，是否开始执行仍遵从该模式。

构建页可暂停 AI 本机执行，显示探测到的命令和运行状态。默认允许自动构建，授权设置随账号保存。Restriction 模式会出现真实命令的审批；Turbo 不需逐项确认。客户端必须运行、联网且具备需要的 SDK；Xcode、证书及依赖不会凭空出现。

## 执行链路

1. 客户端发送消息前注册当前会话的 Intel Mac 与可调用编译命令，随后持续向 HTTPS 网关拉取工作。无需新增公网端口、SSH 或反向入站访问。
2. 网关给本次 AGY 原生终端工具提供私有 `device_tool.py --context ... inspect/build` 调用方式。它是实际执行工具，不是匹配 AI 回复里的“开始编译”文字。每一轮上下文只授权当前会话，并随任务结束撤销。AGY 官方支持原生终端及命令审批，本实现通过终端调用私有 Unix socket 桥。
3. AI 先检查项目和设备，再提交具体命令、项目相对子目录和需要返回的产物。服务器任务继续由 AGY 原生服务器终端完成。Mac 执行不依赖用户打开构建页。
4. 网关按会话审批策略审批 Mac 实际命令，创建单次工作；Mac 领取后取得独立租约，同步当前项目至新的私有副本。不会覆盖已有本机工程。快照沿用 25 MiB/5000 项边界，跳过依赖、构建缓存和凭据目录。
5. Mac 运行真实 Intel 进程，自动上传日志和指定产物（目录先 ZIP），返回真实退出码及路径。日志/产物也加入当前助手消息的附件。AI 工具调用收到结果后可修复服务器源码，并发起新的、明确的构建。单文件上传上限 25 MiB，最多 7 个产物加一份日志。
6. 失联、停止、账号切换或租约过期会停止执行或标为结果不明；已领取工作不自动重派。编译失败的确定结果可由 AI 修复后发起下一次构建。服务重启不会重放工作。新副本保留供查看。

本机命令以当前 Mac 用户身份运行，可能访问该用户可访问的文件；工作副本隔离不等同于操作系统沙箱。输出路径及打包符号链接单独检查，防止无意上传项目外文件。

## 网关升级

先确认当前没有运行中的会话，再将服务的入口改为本仓库 `Server/gateway.py`，保留原有参数。例如：

```bash
python3 /path/to/AGY-Mac/Server/gateway.py \
  --data /existing/account/data \
  --profile-home /existing/account/home \
  --key-file /existing/gateway/key \
  --agy /existing/runtime/agy \
  --root /existing/workspaces
```

连接域名、密钥、历史库及账号不变。`GET /v1/status` 的 `capabilities.aiHybridBuilds` 应为 true。新增接口均沿用网关认证：`POST /v1/sessions/{id}/device`、`POST /v1/devices/{id}/poll`、`POST /v1/builds/{id}`。运行中快照必须同时具备该会话工作编号和有效租约，普通快照仍禁止在运行中读取。

## 验证

Python 覆盖在线发现/会话隔离、单次领取、实际审批参数和拒绝、过期不重派、停止撤权、跨会话附件拒绝及真实 Unix socket CLI 往返。Intel Actions 另运行应用的 `--verify-hybrid` 离线测试：走生产 worker，接收工作、下载/解压快照、运行真实 x86_64 进程、上传日志/产物并回传结果。此测试不调用真实模型、不读取钥匙串，也不代替用户 Xcode 工程和网络环境验证。
