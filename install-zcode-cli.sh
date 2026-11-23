#!/usr/bin/env bash
#
# install-zcode-cli.sh — 一键安装 ZCode CLI/TUI（源码构建单文件版）
#
# 用法:
#   ./install-zcode-cli.sh             # 安装/升级（需要确认的操作会交互询问）
#   ./install-zcode-cli.sh --yes       # 全部按默认值自动确认（自动化/CI 用）
#   ./install-zcode-cli.sh --update    # 同安装（兼容旧参数）
#
# 原则:
#   - 一次性资源（源码、node_modules、临时工具链）全部放临时目录，脚本退出自动删除
#   - 任何会留下东西的操作（装 pnpm 到系统、写 shell rc）必须征得用户同意
#   - 已存在的工具（nvm/系统的 Node、pnpm）直接复用，不算安装
#
# 可用环境变量:
#   ZCODE_REPO / ZCODE_BIN_DIR / ZCODE_NODE_VERSION / ZCODE_PNPM_VERSION
#   ZCODE_NODE_MIRROR（默认 npmmirror，置空只走官方源）/ ZCODE_TARGET（一般无需指定）
#   ZCODE_YES=1          # 等同 --yes
#   ZCODE_KEEP_TEMP=1    # 调试用：失败/退出时保留临时目录
#
set -euo pipefail

REPO_URL="${ZCODE_REPO:-https://github.com/zai-org/ZCode.git}"
BIN_DIR="${ZCODE_BIN_DIR:-$HOME/.local/bin}"
NODE_VERSION="${ZCODE_NODE_VERSION:-24.14.0}"
PNPM_VERSION="${ZCODE_PNPM_VERSION:-10.33.2}"
NODE_MIRROR="${ZCODE_NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
ASSUME_YES="${ZCODE_YES:-0}"

log()  { printf '\033[1;32m[install-zcode]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-zcode][警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-zcode][错误]\033[0m %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
  case "$arg" in
    --yes|-y) ASSUME_YES=1 ;;
    --update) : ;;  # 兼容旧参数：本版本安装与升级为同一流程
    *) die "未知参数: ${arg}（支持 --yes）" ;;
  esac
done

# 交互确认：从 /dev/tty 读取，兼容 curl|bash 管道模式
#   confirm "问题" y   -> 默认是（回车确认）
#   confirm "问题" n   -> 默认否（回车拒绝）
confirm() {
  local question="$1" default="${2:-y}" answer=""
  [ "$ASSUME_YES" = "1" ] && { log "自动确认: ${question}"; return 0; }
  if [ ! -e /dev/tty ]; then
    die "需要交互确认但无终端可用（${question}）。非交互环境请加 --yes 参数"
  fi
  if [ "$default" = "y" ]; then
    printf '\033[1;36m[install-zcode][确认]\033[0m %s [Y/n] ' "$question" >&2
  else
    printf '\033[1;36m[install-zcode][确认]\033[0m %s [y/N] ' "$question" >&2
  fi
  read -r answer </dev/tty || answer=""
  if [ "$default" = "y" ]; then
    case "$answer" in n|N|no|NO|No) return 1 ;; *) return 0 ;; esac
  else
    case "$answer" in y|Y|yes|YES|Yes) return 0 ;; *) return 1 ;; esac
  fi
}

command -v git  >/dev/null 2>&1 || die "缺少 git（macOS: xcode-select --install）"
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v tar  >/dev/null 2>&1 || die "缺少 tar"

# 平台检测
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS/$ARCH" in
  Darwin/arm64)  TARGET="darwin-arm64"; NODE_DIST="darwin-arm64" ;;
  Darwin/x86_64) TARGET="darwin-x64";   NODE_DIST="darwin-x64"   ;;
  Linux/x86_64)  TARGET="linux-x64";    NODE_DIST="linux-x64"    ;;
  Linux/aarch64) TARGET="linux-arm64";  NODE_DIST="linux-arm64"  ;;
  *) die "不支持的平台: $OS/$ARCH" ;;
esac
TARGET="${ZCODE_TARGET:-$TARGET}"

# 临时构建目录：一次性资源全部在这里，退出时自动删除
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/zcode-build.XXXXXX")"
cleanup() {
  if [ "${ZCODE_KEEP_TEMP:-0}" = "1" ]; then
    warn "ZCODE_KEEP_TEMP=1，保留临时目录供排查: $TMPD"
  else
    rm -rf "$TMPD"
  fi
}
trap cleanup EXIT INT TERM

# ---------- 1. 构建工具链（复用已有 or 询问后下载临时副本） ----------
log "步骤 1/5: 准备构建工具链（Node ${NODE_VERSION} + pnpm ${PNPM_VERSION}）"

node_version_ok() { [ -x "$1" ] && "$1" --version 2>/dev/null | grep -q "^v$(echo "$NODE_VERSION" | cut -d. -f1)\."; }
pnpm_ok() { command -v pnpm >/dev/null 2>&1 && pnpm --version 2>/dev/null | grep -q '^10\.'; }

find_node() {
  local n="$HOME/.nvm/versions/node/v$NODE_VERSION/bin/node"
  if [ -x "$n" ]; then echo "$n"; return 0; fi
  if command -v node >/dev/null 2>&1; then
    local v; v="$(node --version | sed 's/^v//')"
    if [ "${v%%.*}" -ge "$(echo "$NODE_VERSION" | cut -d. -f1)" ] 2>/dev/null; then
      command -v node; return 0
    fi
  fi
  return 1
}

# 下载一份临时 Node 到 ${TMPD}（仅本次构建使用，随临时目录删除）
download_temp_node() {
  local tgz="node-v$NODE_VERSION-$NODE_DIST.tar.xz" base ok=0
  for base in "https://nodejs.org/dist/v$NODE_VERSION" "$NODE_MIRROR/v$NODE_VERSION"; do
    [ -n "$base" ] || continue
    log "  尝试下载: $base/$tgz"
    curl -fSL --retry 3 --connect-timeout 15 -o "$TMPD/$tgz" "$base/$tgz" && { ok=1; break; }
  done
  [ "$ok" = "1" ] || die "Node 下载失败，请检查网络"
  tar -xJf "$TMPD/$tgz" -C "$TMPD" && rm -f "$TMPD/$tgz"
  mv "$TMPD/node-v$NODE_VERSION-$NODE_DIST" "$TMPD/node"
}

NODE_BIN="$(find_node || true)"
if [ -n "$NODE_BIN" ]; then
  log "  复用已有 Node: $NODE_BIN ($("$NODE_BIN" --version))"
  if pnpm_ok; then
    log "  复用已有 pnpm $(pnpm --version)"
  elif confirm "缺少 pnpm。是否将 pnpm@$PNPM_VERSION 安装到当前 Node（持久保留，方便复用）？" n; then
    "$(dirname "$NODE_BIN")/npm" install -g "pnpm@$PNPM_VERSION" >/dev/null || die "pnpm 安装失败"
    log "  pnpm 已安装到系统（持久）"
  else
    log "  使用临时工具链（不在系统安装任何东西）"
    download_temp_node
    NODE_BIN="$TMPD/node/bin/node"
    "$TMPD/node/bin/npm" install -g "pnpm@$PNPM_VERSION" >/dev/null || die "临时 pnpm 安装失败"
  fi
else
  log "  未找到 Node $NODE_VERSION"
  if confirm "是否下载 Node ${NODE_VERSION}（约30MB）+ pnpm 到本次临时目录？用完自动删除，不装进系统。（想持久安装可自行 brew/nvm 安装后重跑）" y; then
    download_temp_node
    NODE_BIN="$TMPD/node/bin/node"
    "$TMPD/node/bin/npm" install -g "pnpm@$PNPM_VERSION" >/dev/null || die "临时 pnpm 安装失败"
    log "  临时工具链就绪: $("$NODE_BIN" --version)"
  else
    die "没有可用的构建工具链，退出。请安装 Node $NODE_VERSION 后重试"
  fi
fi
export PATH="$(dirname "$NODE_BIN"):$PATH"
pnpm_ok || die "pnpm 未就绪"
log "  工具链就绪: Node $("$NODE_BIN" --version) + pnpm $(pnpm --version)"

# ---------- 2. 临时目录克隆源码（一次性资源） ----------
log "步骤 2/5: 克隆源码到临时目录（用完即弃）: $TMPD/ZCode"
git clone --depth 1 "$REPO_URL" "$TMPD/ZCode" \
  || die "clone 失败（国内网络可试: ZCODE_REPO=https://ghfast.top/https://github.com/zai-org/ZCode.git 重试）"
cd "$TMPD/ZCode"

# ---------- 3. 安装依赖 + 构建（均在临时目录内） ----------
log "步骤 3/5: 安装依赖 + 构建（首次约 5-15 分钟，全部在临时目录）"
export COREPACK_ENABLE_PROJECT_SPEC=0
export ELECTRON_MIRROR="${ELECTRON_MIRROR:-https://npmmirror.com/mirrors/electron/}"
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
if pnpm install --frozen-lockfile; then
  log "  依赖安装完成"
else
  warn "依赖安装末尾有报错 —— 若仅是桌面版(electron/node-pty/Xcode许可)相关可忽略，继续构建验证"
fi
pnpm build:sea:prepare || die "CLI 构建失败（build:sea:prepare）"

# ---------- 4. 生成 SEA 单文件并自检 ----------
log "步骤 4/5: 生成 SEA 单文件（${TARGET}，内嵌 Node + TUI + 插件）..."
( cd apps/zcode-cli/packages/cli && node scripts/build-sea.mjs --target "$TARGET" ) \
  || die "SEA 打包失败（可加 ZCODE_KEEP_TEMP=1 重跑以保留现场排查）"
SEA_BIN="apps/zcode-cli/packages/cli/dist/zcode-$TARGET"
[ -f "$SEA_BIN" ] || die "SEA 产物缺失: zcode-$TARGET"
chmod +x "$SEA_BIN"
log "  自检: doctor"
"$SEA_BIN" doctor >/dev/null || die "doctor 自检失败"

# ---------- 5. 安装到 bin ----------
log "步骤 5/5: 安装到 ${BIN_DIR}/zcode"
mkdir -p "$BIN_DIR"
cp -f "$SEA_BIN" "$BIN_DIR/zcode"
chmod +x "$BIN_DIR/zcode"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    RC_FILE="$HOME/.zshrc"
    [ -n "${BASH_VERSION:-}" ] && RC_FILE="$HOME/.bashrc"
    if confirm "PATH 中没有 ${BIN_DIR}，是否写入 ${RC_FILE}（一行，带标记可回溯）？" y; then
      printf '\nexport PATH="%s:$PATH"  # added by install-zcode-cli\n' "$BIN_DIR" >>"$RC_FILE"
      warn "已写入，新开终端生效"
    else
      warn "未修改 PATH，请自行将 ${BIN_DIR} 加入 PATH"
    fi
    ;;
esac

for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$RC" ] && grep -qs "^alias zcode=" "$RC" && warn "$RC 中存在 zcode 别名，会遮蔽安装的程序，请删除该 alias 行"
done

log "安装完成 ✅（临时目录已自动清理）"
echo
echo "  用法:  zcode              # 进入 TUI"
echo "         zcode -p \"提示词\"   # 无头单次调用"
echo "         zcode login bigmodel / zcode login zai   # 登录（与桌面版共用账号）"
echo "  升级:  重新运行本脚本即可；自动化场景加 --yes 跳过确认"
echo "  特性:  单文件自包含（内嵌 Node/TUI/插件），运行时零依赖；"
echo "         登录凭证/套餐/优惠与桌面版共享；开会话前建议退出桌面版（共用数据库）"
