#!/usr/bin/env bash
#
# install-zcode-cli.sh — 一键安装 ZCode CLI/TUI（源码构建单文件版）
#
# 用法:
#   ./install-zcode-cli.sh            # 安装/升级（同一流程，可重复执行）
#   ./install-zcode-cli.sh --update   # 同上（兼容旧参数）
#
# 流程: 临时目录 clone 源码 → 构建 SEA 单文件可执行 → 装到 ~/.local/bin/zcode
#       → 删除临时目录。不留下源码，不写死任何项目目录，运行时零依赖（Node 已内嵌）。
#
# 可用环境变量覆盖默认值:
#   ZCODE_REPO=https://github.com/zai-org/ZCode.git
#   ZCODE_BIN_DIR=$HOME/.local/bin
#   ZCODE_NODE_VERSION=24.14.0
#   ZCODE_PNPM_VERSION=10.33.2
#   ZCODE_NODE_MIRROR=https://npmmirror.com/mirrors/node   # 置空则只走官方源
#   ZCODE_TARGET=darwin-arm64                              # 一般无需指定，自动检测
#
set -euo pipefail

REPO_URL="${ZCODE_REPO:-https://github.com/zai-org/ZCode.git}"
BIN_DIR="${ZCODE_BIN_DIR:-$HOME/.local/bin}"
NODE_VERSION="${ZCODE_NODE_VERSION:-24.14.0}"
PNPM_VERSION="${ZCODE_PNPM_VERSION:-10.33.2}"
NODE_MIRROR="${ZCODE_NODE_MIRROR:-https://npmmirror.com/mirrors/node}"
NODE_CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/zcode-installer"   # 构建工具缓存，可随时删

log()  { printf '\033[1;32m[install-zcode]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install-zcode][警告]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[install-zcode][错误]\033[0m %s\n' "$*" >&2; exit 1; }

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

# 临时构建目录（脚本退出时自动删除）
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/zcode-build.XXXXXX")"
cleanup() { rm -rf "$TMPD"; }
trap cleanup EXIT INT TERM

# ---------- 1. 构建用 Node（仅构建期需要，运行时不需要） ----------
log "步骤 1/5: 准备构建用 Node $NODE_VERSION"
NODE_BIN=""
NVM_NODE="$HOME/.nvm/versions/node/v$NODE_VERSION/bin/node"
if [ -x "$NVM_NODE" ]; then
  NODE_BIN="$NVM_NODE"; log "  复用 nvm 的 Node: $NODE_BIN"
elif command -v node >/dev/null 2>&1; then
  SYS_VER="$(node --version | sed 's/^v//')"; SYS_MAJOR="${SYS_VER%%.*}"; NEED_MAJOR="${NODE_VERSION%%.*}"
  if [ "$SYS_MAJOR" -ge "$NEED_MAJOR" ] 2>/dev/null; then
    NODE_BIN="$(command -v node)"; log "  复用系统 Node: $NODE_BIN ($SYS_VER)"
  fi
fi
if [ -z "$NODE_BIN" ]; then
  if [ -x "$NODE_CACHE/node-v$NODE_VERSION/bin/node" ]; then
    NODE_BIN="$NODE_CACHE/node-v$NODE_VERSION/bin/node"; log "  复用缓存: $NODE_BIN"
  else
    log "  下载 Node 到缓存目录 ${NODE_CACHE}（可随时删除）"
    TARBALL="node-v$NODE_VERSION-$NODE_DIST.tar.xz"
    DL_OK=0
    for BASE in "https://nodejs.org/dist/v$NODE_VERSION" "$NODE_MIRROR/v$NODE_VERSION"; do
      [ -n "$BASE" ] || continue
      log "  尝试下载: $BASE/$TARBALL"
      if curl -fSL --retry 3 --connect-timeout 15 -o "$TMPD/$TARBALL" "$BASE/$TARBALL"; then DL_OK=1; break; fi
    done
    [ "$DL_OK" = "1" ] || die "Node 下载失败，请检查网络"
    mkdir -p "$NODE_CACHE/node-v$NODE_VERSION"
    tar -xJf "$TMPD/$TARBALL" -C "$TMPD"
    mv "$TMPD/node-v$NODE_VERSION-$NODE_DIST"/* "$NODE_CACHE/node-v$NODE_VERSION/"
    rm -f "$TMPD/$TARBALL"
    NODE_BIN="$NODE_CACHE/node-v$NODE_VERSION/bin/node"
  fi
fi
NODE_BIN_DIR="$(dirname "$NODE_BIN")"
export PATH="$NODE_BIN_DIR:$PATH"
log "  使用 Node $("$NODE_BIN" --version)（仅构建期）"

# ---------- 2. pnpm ----------
log "步骤 2/5: 准备 pnpm $PNPM_VERSION"
if ! command -v pnpm >/dev/null 2>&1 || ! pnpm --version 2>/dev/null | grep -q '^10\.'; then
  "$NODE_BIN_DIR/npm" install -g "pnpm@$PNPM_VERSION" >/dev/null || die "pnpm 安装失败"
fi
log "  pnpm $(pnpm --version) 就绪"

# ---------- 3. 临时目录克隆源码 ----------
log "步骤 3/5: 克隆源码到临时目录（用完即弃）: $TMPD/ZCode"
git clone --depth 1 "$REPO_URL" "$TMPD/ZCode" \
  || die "clone 失败（国内网络可试: ZCODE_REPO=https://ghfast.top/https://github.com/zai-org/ZCode.git 重试）"
cd "$TMPD/ZCode"

# ---------- 4. 安装依赖并构建 SEA 单文件 ----------
log "步骤 4/5: 安装依赖 + 构建（首次约 5-15 分钟）"
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
log "  生成 SEA 单文件（${TARGET}，内嵌 Node + TUI + 插件）..."
( cd apps/zcode-cli/packages/cli && node scripts/build-sea.mjs --target "$TARGET" ) \
  || die "SEA 打包失败"
SEA_BIN="apps/zcode-cli/packages/cli/dist/zcode-$TARGET"
[ -f "$SEA_BIN" ] || die "SEA 产物缺失: zcode-$TARGET"
chmod +x "$SEA_BIN"

# 临时位置自检
log "  自检: $SEA_BIN doctor"
"$SEA_BIN" doctor >/dev/null || die "doctor 自检失败"

# ---------- 5. 安装到 bin ----------
log "步骤 5/5: 安装到 $BIN_DIR/zcode"
mkdir -p "$BIN_DIR"
cp -f "$SEA_BIN" "$BIN_DIR/zcode"
chmod +x "$BIN_DIR/zcode"

# PATH 提示（仅在 rc 里补一行，带标记可回溯）
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *)
    RC_FILE="$HOME/.zshrc"
    [ -n "${BASH_VERSION:-}" ] && RC_FILE="$HOME/.bashrc"
    printf '\nexport PATH="%s:$PATH"  # added by install-zcode-cli\n' "$BIN_DIR" >>"$RC_FILE"
    warn "已将 ${BIN_DIR} 加入 PATH（写入 ${RC_FILE}），新开终端生效"
    ;;
esac

# 提醒别名遮蔽
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ -f "$RC" ] && grep -qs "^alias zcode=" "$RC" && warn "$RC 中存在 zcode 别名，会遮蔽安装的程序，请删除该 alias 行"
done

log "安装完成 ✅（临时构建目录已自动清理）"
echo
echo "  用法:  zcode              # 进入 TUI"
echo "         zcode -p \"提示词\"   # 无头单次调用"
echo "         zcode login bigmodel / zcode login zai   # 登录（与桌面版共用账号）"
echo "  升级:  重新运行本脚本即可（全新构建后覆盖）"
echo "  特性:  单文件自包含（内嵌 Node/TUI/插件），运行时零依赖；"
echo "         登录凭证/套餐/优惠与桌面版共享；开会话前建议退出桌面版（共用数据库）"
