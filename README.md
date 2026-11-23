# ai-agent-installation

AI 编程工具的一键安装脚本集合。所有脚本无交互、可重复执行、支持 `curl | bash` 管道安装。

## install-zcode-cli.sh

从 [zai-org/ZCode](https://github.com/zai-org/ZCode) 官方源码构建 ZCode CLI/TUI 的 **SEA 单文件版**，安装为 `~/.local/bin/zcode`。

官方不提供独立 CLI 发行包，桌面应用内也不含 TUI 运行时 —— 本脚本是获得终端 TUI 的唯一途径。

### 架构

```
临时目录 clone 源码 → 构建 → 产出单文件可执行（内嵌 Node/TUI/插件/Playwright，约 250MB）
        → 安装到 ~/.local/bin/zcode → 自动删除临时目录
```

- **不留源码、不写死项目目录**：源码随临时目录用完即弃
- **运行时零依赖**：Node 已内嵌，目标机器不需要装任何运行时
- 仅构建期需要 Node 24/pnpm（自动准备：优先复用 nvm/系统已有，否则下载到缓存目录 `~/.cache/zcode-installer/`，可随时删）
- 仅需 `git` + `curl` + `tar`；macOS（Intel/Apple Silicon）与 Linux（x64/arm64）均支持

### 安装（新机器上执行）

```bash
curl -fsSL https://raw.githubusercontent.com/luisz08/ai-agent-installation/main/install-zcode-cli.sh | bash
```

### 升级

```bash
curl -fsSL https://raw.githubusercontent.com/luisz08/ai-agent-installation/main/install-zcode-cli.sh | bash -s -- --update
```

### 使用

```bash
zcode                    # 进入 TUI
zcode -p "提示词"        # 无头单次调用
zcode login bigmodel     # 首次登录（zai / bigmodel，与桌面版共用账号凭证）
```

### 说明

- 登录凭证（`~/.zcode/v2/credentials.json`）、套餐额度、优惠活动与 ZCode 桌面版完全共享 —— 构建自未改动的官方源码，客户端身份一致。
- TUI 中打开会话前建议退出 ZCode 桌面应用（共用 `~/.zcode/cli/db`，同时运行会锁库）。
- 构建失败常见原因排查：
  - 桌面版组件（electron/node-pty/Xcode 许可）编译失败 → 正常，脚本会自动忽略，CLI 不受影响
  - 依赖安装末尾报错但构建继续 → 同上
- 可用环境变量：`ZCODE_REPO`、`ZCODE_BIN_DIR`、`ZCODE_NODE_VERSION`、`ZCODE_PNPM_VERSION`、`ZCODE_NODE_MIRROR`（默认 npmmirror，置空走官方源）、`ZCODE_TARGET`（一般无需指定）。
