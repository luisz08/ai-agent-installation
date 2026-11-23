# ai-agent-installation

AI 编程工具的一键安装脚本集合。所有脚本无交互、可重复执行、支持 `curl | bash` 管道安装。

## install-zcode-cli.sh

从 [zai-org/ZCode](https://github.com/zai-org/ZCode) 官方源码构建 ZCode CLI/TUI（官方不提供独立 CLI 发行包，桌面应用内也不含 TUI 运行时），并安装 `zcode` 启动器。

自动处理：Node 24.14.0（复用 nvm/系统的，否则下载独立副本不污染系统）、pnpm、源码 clone（--depth 1）、依赖安装（自动跳过 Electron/浏览器下载，容忍桌面版编译失败）、构建 + 启动器安装到 `~/.local/bin`。

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

- 登录凭证、套餐额度与 ZCode 桌面版完全共享（`~/.zcode/v2/credentials.json`），Coding Plan 的优惠活动同样生效。
- TUI 中打开会话前建议退出 ZCode 桌面应用（共用 `~/.zcode/cli/db`，同时运行会锁库）。
- 可用环境变量覆盖默认值：`ZCODE_REPO`、`ZCODE_INSTALL_DIR`（默认 `~/source/repos/ZCode`）、`ZCODE_BIN_DIR`、`ZCODE_NODE_VERSION`、`ZCODE_PNPM_VERSION`、`ZCODE_NODE_MIRROR`（默认 npmmirror，置空走官方源）。
- 仅依赖 `git` + `curl` + `tar`；Linux（x64/arm64）与 macOS（Intel/Apple Silicon）均支持。
