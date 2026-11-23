#!/usr/bin/env bash
#
# install-zcode-cli.sh — 一键安装 ZCode CLI/TUI（源码构建版）
#
# 用法:
#   ./install-zcode-cli.sh            # 安装（已存在则跳过 clone，重新构建）
#   ./install-zcode-cli.sh --update   # 升级：git pull 后重新构建
#
# 功能:
#   1. 自动准备 Node 24.14.0（优先复用 nvm/系统已装的，否则下载独立副本，不污染系统）
#   2. 自动准备 pnpm 10.33.2
#   3. 克隆 https://github.com/zai-org/ZCode（--depth 1）
#   4. 安装依赖并构建 @zcode/cli（含 TUI）
#   5. 安装 zcode 启动器到 ~/.local/bin
#
# 可用环境变量覆盖默认值:
#   ZCODE_REPO=https://github.com/zai-org/ZCode.git
#   ZCODE_INSTALL_DIR=$HOME/source/repos/ZCode
#   ZCODE_BIN_DIR=$HOME/.local/bin
#   ZCODE_NODE_VERSION=24.14.0
#   ZCODE_PNPM_VERSION=10.33.2
#   ZCODE_NODE_MIRROR=https://npmmirror.com/mirrors/node   # 置空则只走官方源
#
set -euo pipefail

# ---------- 配置 ----------
REPO_URL="${ZCODE_REPO:-https://github.com/zai-org/ZCode.git}"
INSTALL_DIR="${ZCODE_INSTALL_DIR:-$HOME/source/repos/ZCode}"
BIN_DIR="${ZCODE_BIN_DIR:-$HOME/.local/bin}"
NODE_VERSION="${ZCODE_NODE_VERSION:-24.14.0}"
PNPM_VERSION="${ZCODE_PNPM_VERSION:-10.33.2}"
NODE_MIRROR="${ZCODE_NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
SELF_NODE_HOME="$HOME/.local/share/zcode-installer/node-v$NODE_VERSION"

log()  { printf '\033[1;32m[install-zcode]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-zcode][警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-zcode][错误]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 0. 基础检查 ----------
command -v git  >/dev/null 2>&1 || die "缺少 git，请先安装（macOS: xcode-select --install）"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar  >/dev/null 2>&1 || die "缺少 tar"

UPDATE_ONLY=0
[ "${1:-}" = "--update" ] && UPDATE_ONLY=1

OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS/$ARCH" in
  Darwin/arm64)  NODE_DIST="darwin-arm64" ;;
  Darwin/x86_64) NODE_DIST="darwin-x64"   ;;
  Linux/x86_64)  NODE_DIST="linux-x64"    ;;
  Linux/aarch64) NODE_DIST="linux-arm64"  ;;
  *) die "不支持的平台: $OS/$ARCH" ;;
esac

# ---------- 1. 解析 Node ----------
log "步骤 1/6: 准备 Node $NODE_VERSION ($NODE_DIST)"
NODE_BIN=""
# 优先级: nvm 已装 > 系统已装(>=24) > 下载独立副本
NVM_NODE="$HOME/.nvm/versions/node/v$NODE_VERSION/bin/node"
if [ -x "$NVM_NODE" ]; then
  NODE_BIN="$NVM_NODE"; log "  复用 nvm 的 Node: $NODE_BIN"
elif command -v node >/dev/null 2>&1; then
  SYS_VER="$(node --version | sed 's/^v//')"
  SYS_MAJOR="${SYS_VER%%.*}"
  NEED_MAJOR="${NODE_VERSION%%.*}"
  if [ "$SYS_MAJOR" -ge "$NEED_MAJOR" ] 2>/dev/null; then
    NODE_BIN="$(command -v node)"; log "  复用系统 Node: $NODE_BIN ($SYS_VER)"
  fi
fi
if [ -z "$NODE_BIN" ]; then
  if [ -x "$SELF_NODE_HOME/bin/node" ]; then
    NODE_BIN="$SELF_NODE_HOME/bin/node"; log "  复用独立副本: $NODE_BIN"
  else
    log "  未找到 Node $NODE_VERSION，下载独立副本到 $SELF_NODE_HOME（不污染系统）"
    TARBALL="node-v$NODE_VERSION-$NODE_DIST.tar.xz"
    mkdir -p "$(dirname "$SELF_NODE_HOME")"
    TMPD="$(mktemp -d)"
    DL_OK=0
    for BASE in "https://nodejs.org/dist/v$NODE_VERSION" "$NODE_MIRROR/v$NODE_VERSION"; do
      [ -n "$BASE" ] || continue
      log "  尝试下载: $BASE/$TARBALL"
      if curl -fSL --retry 3 --connect-timeout 15 -o "$TMPD/$TARBALL" "$BASE/$TARBALL"; then DL_OK=1; break; fi
    done
    [ "$DL_OK" = "1" ] || die "Node 下载失败，请检查网络或手动安装 Node $NODE_VERSION"
    mkdir -p "$SELF_NODE_HOME"
    tar -xJf "$TMPD/$TARBALL" -C "$TMPD"
    mv "$TMPD/node-v$NODE_VERSION-$NODE_DIST"/* "$SELF_NODE_HOME/"
    rm -rf "$TMPD"
    NODE_BIN="$SELF_NODE_HOME/bin/node"
    log "  Node 已就绪: $NODE_BIN"
  fi
fi
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_BIN_DIR:$PATH"
"$NODE_BIN" --version | grep -q "^v$(echo "$NODE_VERSION" | cut -d. -f1)\." || die "Node 版本异常"
log "  当前使用: $("$NODE_BIN" --version) ($NODE_BIN)"

# ---------- 2. 准备 pnpm ----------
log "步骤 2/6: 准备 pnpm $PNPM_VERSION"
if ! command -v pnpm >/dev/null 2>&1 || ! pnpm --version 2>/dev/null | grep -q '^10\.'; then
  log "  通过 npm 安装 pnpm@$PNPM_VERSION（装入当前 Node 目录）"
  "$NODE_BIN_DIR/npm" install -g "pnpm@$PNPM_VERSION" >/dev/null || die "pnpm 安装失败"
fi
log "  pnpm $(pnpm --version) 就绪"

# ---------- 3. 源码 ----------
log "步骤 3/6: 获取源码 -> $INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
  if [ "$UPDATE_ONLY" = "1" ]; then
    log "  git pull 更新源码"
    git -C "$INSTALL_DIR" pull --ff-only || warn "git pull 失败（可能有本地改动），继续用现有代码构建"
  else
    log "  源码已存在，跳过 clone（如需更新用 --update）"
  fi
else
  [ "$UPDATE_ONLY" = "1" ] && die "--update 需要已有源码目录: $INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  log "  git clone --depth 1 $REPO_URL"
  git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" || die "clone 失败（国内网络可试: ZCODE_REPO=https://ghfast.top/https://github.com/zai-org/ZCode.git 重试）"
fi

# ---------- 4. 安装依赖 ----------
log "步骤 4/6: 安装依赖（首次约 3-10 分钟）"
cd "$INSTALL_DIR"
export COREPACK_ENABLE_PROJECT_SPEC=0
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1      # CLI 不需要 electron 二进制
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1   # 跳过浏览器下载
if pnpm install --frozen-lockfile; then
  log "  依赖安装完成"
else
  warn "依赖安装末尾有报错 —— 若仅是桌面版(electron/node-pty/Xcode许可)相关可忽略，CLI 不受影响；继续构建验证"
fi

# ---------- 5. 构建 ----------
log "步骤 5/6: 构建 @zcode/cli（含 TUI）"
pnpm --filter '@zcode/cli...' build || die "CLI 构建失败，请把上方完整日志反馈"
CLI_CJS="$INSTALL_DIR/apps/zcode-cli/packages/cli/dist/zcode.cjs"
[ -f "$CLI_CJS" ] || die "构建产物缺失: $CLI_CJS"
log "  构建成功: $CLI_CJS ($(( $(wc -c <"$CLI_CJS") / 1024 / 1024 ))MB)"

# ---------- 6. 安装启动器 ----------
log "步骤 6/6: 安装启动器 -> $BIN_DIR/zcode"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/zcode" <<LAUNCHER
#!/bin/sh
# 由 install-zcode-cli.sh 生成 — ZCode CLI/TUI 启动器
NODE_BIN="$NODE_BIN"
CLI_CJS="$CLI_CJS"
# ZCode 桌面应用运行时会锁会话数据库，给出提示
if pgrep -f "ZCode.app/Contents/MacOS" >/dev/null 2>&1; then
  echo "zcode: 检测到 ZCode 桌面应用正在运行（会锁 ~/.zcode/cli/db），如遇数据库报错请先退出桌面应用" >&2
fi
exec "\$NODE_BIN" "\$CLI_CJS" "\$@"
LAUNCHER
chmod +x "$BIN_DIR/zcode"

# PATH 提示（仅在 rc 里补一行，带标记可回溯）
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    RC_FILE="$HOME/.zshrc"
    [ -n "${BASH_VERSION:-}" ] && RC_FILE="$HOME/.bashrc"
    printf '\nexport PATH="%s:$PATH"  # added by install-zcode-cli\n' "$BIN_DIR" >>"$RC_FILE"
    warn "已将 $BIN_DIR 加入 PATH（写入 $RC_FILE），新开终端或执行 source 后生效"
    ;;
esac

# 提醒别名遮蔽
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$RC" ] && grep -qs "^alias zcode=" "$RC" && warn "$RC 中存在 zcode 别名，会遮蔽启动器，请手动删除该 alias 行"
done

# ---------- 验证 ----------
log "验证: zcode doctor"
"$NODE_BIN" "$CLI_CJS" doctor >/dev/null || die "doctor 自检失败"
log "安装完成 ✅"
echo
echo "  用法:  zcode              # 进入 TUI"
echo "         zcode -p \"提示词\"   # 无头单次调用"
echo "         zcode login bigmodel / zcode login zai   # 登录（与桌面版共用账号）"
echo "  升级:  install-zcode-cli.sh --update"
echo "  注意:  TUI 里开会话前请退出 ZCode 桌面应用（共用数据库）; 1.5 倍额度与桌面版同样生效"
