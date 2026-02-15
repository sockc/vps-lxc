#!/usr/bin/env bash
# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v5.1)
# 修复: 安全更新脚本路径、容器选择越界、状态读取更稳、启动等待
# 特性: 输入清洗、双 shell 进入、菜单兜底、危险操作二次确认
# ====================================================

# ---- Colors ----
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---- Safe shell options (不使用 set -e，避免交互脚本因非关键失败直接退出) ----
set -u
set -o pipefail

# ---- Script identity / update ----
SELF_SRC="${BASH_SOURCE[0]-$0}"
SCRIPT_PATH="$(readlink -f "$SELF_SRC" 2>/dev/null || realpath "$SELF_SRC" 2>/dev/null || echo "$SELF_SRC")"
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# 如果脚本来自 bash <(curl...)，SCRIPT_PATH 往往是 /dev/fd/*，更新必须落盘到固定位置
INSTALL_FALLBACK="/usr/local/bin/sockc-lxc.sh"

# ---- Globals ----
containers=()
statuses=()

# ---- UI helpers ----
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR ]${NC} $*"; }

pause() { read -r -p "按回车继续..." < /dev/tty; }

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "请用 root 运行（sudo -i 或 sudo bash $0）"
    exit 1
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { err "缺少命令: $1"; exit 1; }
}

sanitize_input() {
  local s="${1:-}"
  s="${s//$'\r'/}"
  s="${s//[[:space:]]/}"
  printf '%s' "$s"
}

safe_script_path_for_update() {
  if [[ "$SCRIPT_PATH" == /dev/fd/* || "$SCRIPT_PATH" == /proc/*/fd/* ]]; then
    echo "$INSTALL_FALLBACK"
  else
    echo "$SCRIPT_PATH"
  fi
}

# ---- LXC/LXD base check ----
ensure_lxc() {
  need_cmd lxc
  # lxc 连接失败时给个可读提示
  if ! lxc info >/dev/null 2>&1; then
    err "lxc 无法连接到 LXD（可能 LXD 服务未启动 / snap lxd 未安装 / 权限问题）"
    echo -e "${YELLOW}排查建议:${NC}"
    echo "  1) lxc info"
    echo "  2) systemctl status snap.lxd.daemon  (Ubuntu/snap)"
    echo "  3) journalctl -u snap.lxd.daemon -n 80 --no-pager"
    pause
    return 1
  fi
  return 0
}

# ---- Container list/cache ----
refresh_containers() {
  containers=()
  statuses=()
  while IFS=',' read -r n s; do
    [[ -n "${n:-}" ]] || continue
    containers+=("$n")
    statuses+=("${s:-UNKNOWN}")
  done < <(lxc list -c ns --format csv 2>/dev/null || true)
}

list_containers() {
  refresh_containers
  if [ ${#containers[@]} -eq 0 ]; then
    warn "目前没有任何容器。"
    return 1
  fi

  echo -e "${BLUE}现有容器列表:${NC}"
  for i in "${!containers[@]}"; do
    local show=$((i+1))
    printf "  [%d] %-20s (%s)\n" "$show" "${containers[$i]}" "${statuses[$i]}"
  done
  return 0
}

get_status() {
  # 不依赖 lxc info 输出格式
  lxc list "$1" -c s --format csv 2>/dev/null | head -n 1 | tr -d '\r'
}

wait_running() {
  local name="$1"
  local timeout="${2:-25}"
  local i=0 st=""
  while (( i < timeout )); do
    st="$(get_status "$name")"
    [[ "$st" == "RUNNING" ]] && return 0
    sleep 1
    ((i++))
  done
  return 1
}

resolve_target() {
  # 支持：输入 1-based 编号 或 直接输入名字
  local input="$1"
  local target=""

  if [[ "$input" =~ ^[0-9]+$ ]]; then
    local idx=$((input-1))
    if (( idx < 0 || idx >= ${#containers[@]} )); then
      return 1
    fi
    target="${containers[$idx]}"
  else
    target="$input"
  fi

  [[ -n "$target" ]] || return 1
  printf '%s' "$target"
}

# ---- Enter container ----
enter_container() {
  ensure_lxc || return
  list_containers || { sleep 1; return; }

  lxc_exec_tty() {
  local ct="$1"; shift
  # 如果脚本 stdin/stdout 不是 TTY（管道/进程替换执行），强制绑到 /dev/tty
  if [[ -t 0 && -t 1 ]]; then
    lxc exec "$ct" -- "$@"
  else
    lxc exec "$ct" -- "$@" < /dev/tty > /dev/tty 2>&1
  fi
}

  echo -e "${YELLOW}提示: 直接输入容器名字最稳；也可输入编号（从 1 开始）${NC}"
  read -r -p "请输入名字或编号: " input < /dev/tty
  input="$(sanitize_input "$input")"

  local target=""
  if ! target="$(resolve_target "$input")"; then
    err "编号越界或输入无效，请重新输入。"
    pause
    return
  fi

  local status
  status="$(get_status "$target")"
  if [[ -z "$status" ]]; then
    err "找不到容器 '$target'，请确认名字是否拼错。"
    pause
    return
  fi

  if [[ "$status" != "RUNNING" ]]; then
    warn "$target 当前处于 $status，尝试启动..."
    if ! lxc start "$target" >/dev/null 2>&1; then
      err "启动失败：lxc start $target"
      echo -e "${YELLOW}建议执行:${NC}"
      echo "  lxc info $target"
      echo "  lxc console --show-log $target"
      pause
      return
    fi
    if ! wait_running "$target" 25; then
      err "启动超时：$target 仍未进入 RUNNING"
      echo -e "${YELLOW}建议执行:${NC}"
      echo "  lxc info $target"
      echo "  lxc console --show-log $target"
      pause
      return
    fi
  fi

  ok "正在连接 $target ...（退出后会回到菜单）"

  # 更通用：明确 shell 路径
if ! lxc_exec_tty "$target" /bin/bash -li; then
  echo -e "${YELLOW}⚠️  /bin/bash 不可用，尝试 /bin/sh 进入...${NC}"
  if ! lxc_exec_tty "$target" /bin/sh -l; then
      err "------------------------------------"
      err "致命错误: 无法进入容器 '$target'"
      echo -e "${YELLOW}可能原因:${NC}"
      echo "  1. 容器初始化未完成 / init 崩溃"
      echo "  2. 容器内部没有可用 shell（极少见）"
      echo "  3. 容器文件系统/权限异常"
      echo -e "${YELLOW}排查建议:${NC}"
      echo "  lxc info $target"
      echo "  lxc console --show-log $target"
      echo "  lxc exec $target -- ls -la /"
      err "------------------------------------"
      pause
    fi
  fi
}
detect_host_lxd_arch() {
  # uname -m -> LXD images server 常见架构名
  local m
  m="$(uname -m 2>/dev/null || echo unknown)"
  case "$m" in
    x86_64|amd64) echo "x86_64" ;;
    aarch64|arm64) echo "aarch64" ;;
    armv7l|armv7*) echo "armv7l" ;;
    armv6l|armv6*) echo "armv6l" ;;
    i386|i686) echo "i686" ;;
    ppc64le) echo "ppc64le" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *) echo "$m" ;;
  esac
}

HOST_LXD_ARCH="$(detect_host_lxd_arch)"

# --- 从 images: 取别名，过滤只要 CONTAINER ---
_image_aliases_container_only() {
  local distro="$1"
  local arch="${2:-$HOST_LXD_ARCH}"
  local all generic

  # 优先走：alias,arch,type（三列）
  all="$(
    lxc image list images: "$distro" -c l,a,t --format csv 2>/dev/null \
      | tr -d '\r' \
      | awk -F',' -v A="$arch" '$3=="CONTAINER" && $2==A {print $1}'
  )"

  # 如果当前 lxc 不支持 -c a（极少数老版本），回退到旧逻辑
  if [[ -z "${all:-}" ]]; then
    all="$(
      lxc image list images: "$distro" -c l,t --format csv 2>/dev/null \
        | tr -d '\r' \
        | awk -F',' '$2=="CONTAINER"{print $1}'
    )"
  fi

  # 优先保留“通用别名”（不带 /amd64 /aarch64 这种后缀），方便后续拼 /cloud
  generic="$(
    echo "$all" | grep -Ev '/(amd64|arm64|aarch64|x86_64|i686|armv7l|armv6l|riscv64|ppc64le|s390x)$' || true
  )"

  if [[ -n "${generic:-}" ]]; then
    echo "$generic"
  else
    echo "$all"
  fi
}

# --- Ubuntu 版本列表（只取 ubuntu/YY.MM）---
get_ubuntu_versions() {
  _image_aliases_container_only ubuntu \
    | grep -E '^ubuntu/[0-9]{2}\.[0-9]{2}$' \
    | sed 's#^ubuntu/##' \
    | sort -V
}

# --- Debian 版本列表（只取 debian/数字）---
get_debian_versions() {
  _image_aliases_container_only debian \
    | grep -E '^debian/[0-9]+$' \
    | sed 's#^debian/##' \
    | sort -V
}

# --- Alpine 版本列表（只取 alpine/X.Y）---
get_alpine_versions() {
  _image_aliases_container_only alpine \
    | grep -E '^alpine/[0-9]+\.[0-9]+$' \
    | sed 's#^alpine/##' \
    | sort -V
}

# --- 通用：从版本列表里让用户选（编号或直接输入版本号）---
_select_version_from_list() {
  local title="$1" versions="$2" default_ver="$3"
  local v picked

  echo -e "${BLUE}${title}${NC}"
  echo "$versions" | tail -n 10 | nl -w2 -s') '

  echo -e "${YELLOW}直接回车 = 默认 ${default_ver}${NC}"
  read -r -p "选择版本(输入编号或直接输入版本号): " v < /dev/tty
  v="$(sanitize_input "${v:-}")"

  if [[ -z "$v" ]]; then
    v="$default_ver"
  elif [[ "$v" =~ ^[0-9]+$ ]]; then
    picked="$(echo "$versions" | tail -n 10 | sed -n "${v}p")"
    [[ -n "$picked" ]] && v="$picked"
  fi

  echo "$v"
}

# --- 通用：default / cloud 变体选择 ---
_select_variant() {
  local variant
  read -r -p "变体：1=default  2=cloud (默认 1): " variant < /dev/tty
  variant="$(sanitize_input "${variant:-}")"
  [[ "$variant" == "2" ]] && echo "cloud" || echo "default"
}

# --- Ubuntu 动态选择：默认选“最新 LTS（*.04）”，否则选最新 ---
select_ubuntu_image() {
  local versions latest latest_lts ver variant

  versions="$(get_ubuntu_versions || true)"
  latest="$(echo "$versions" | tail -n 1)"
  latest_lts="$(echo "$versions" | grep -E '\.04$' | tail -n 1)"

  if [[ -z "${latest:-}" ]]; then
    # 远程不可用时兜底（你也可以改成提示用户自定义输入）
    echo "images:ubuntu/24.04"
    return 0
  fi

  # 默认：优先 LTS
  ver="${latest_lts:-$latest}"
  echo -e "${YELLOW}提示: Ubuntu 默认优先选择最新 LTS（*.04）。最新版本=${latest}，最新 LTS=${ver}${NC}"
  ver="$(_select_version_from_list "可用 Ubuntu 版本（CONTAINER）:" "$versions" "$ver")"

  variant="$(_select_variant)"
  if [[ "$variant" == "cloud" ]]; then
    echo "images:ubuntu/${ver}/cloud"
  else
    echo "images:ubuntu/${ver}"
  fi
}

# --- Debian 动态选择：默认选最新数字版 ---
select_debian_image() {
  local versions latest ver variant

  versions="$(get_debian_versions || true)"
  latest="$(echo "$versions" | tail -n 1)"
  if [[ -z "${latest:-}" ]]; then
    echo "images:debian/12"
    return 0
  fi

  ver="$(_select_version_from_list "可用 Debian 版本（CONTAINER）:" "$versions" "$latest")"
  variant="$(_select_variant)"
  if [[ "$variant" == "cloud" ]]; then
    echo "images:debian/${ver}/cloud"
  else
    echo "images:debian/${ver}"
  fi
}

# --- Alpine 动态选择：默认选最新 X.Y ---
select_alpine_image() {
  local versions latest ver variant

  versions="$(get_alpine_versions || true)"
  latest="$(echo "$versions" | tail -n 1)"
  if [[ -z "${latest:-}" ]]; then
    echo "images:alpine/edge"
    return 0
  fi

  ver="$(_select_version_from_list "可用 Alpine 版本（CONTAINER）:" "$versions" "$latest")"
  variant="$(_select_variant)"
  if [[ "$variant" == "cloud" ]]; then
    echo "images:alpine/${ver}/cloud"
  else
    echo "images:alpine/${ver}"
  fi
}

# ---- Create container (基础可用版) ----
create_container() {
  ensure_lxc || return
  echo -e "${YELLOW}当前镜像架构过滤：${HOST_LXD_ARCH}${NC}"

  echo -e "${BLUE}常用镜像示例:${NC}"
  echo "  1) images:ubuntu (动态版本)"
  echo "  2) images:debian (动态版本)"
  echo "  3) images:alpine (动态版本)"
  echo "  4) 自定义输入"
  read -r -p "选择镜像 [1-4] (默认 1): " ch < /dev/tty
  ch="$(sanitize_input "${ch:-}")"
  local image="images:ubuntu/24.04"
  case "${ch:-1}" in
    1|"") image="$(select_ubuntu_image)" ;;
    2) image="$(select_debian_image)" ;;
    3) image="$(select_alpine_image)" ;;
    4)
      read -r -p "请输入镜像别名（如 images:ubuntu/22.04）: " image < /dev/tty
      image="$(sanitize_input "$image")"
      ;;
    *) warn "无效选择，使用默认镜像 images:ubuntu/24.04" ;;
  esac

  local def_name="ct-$(date +%Y%m%d-%H%M%S)"
  read -r -p "容器名称 (默认: $def_name): " name < /dev/tty
  name="$(sanitize_input "${name:-}")"
  [[ -z "$name" ]] && name="$def_name"

  info "创建容器：$name  镜像：$image"
  if lxc launch "$image" "$name"; then
    ok "创建成功：$name"
    echo -e "${YELLOW}提示: 初次启动可能需要一点时间${NC}"
  else
    err "创建失败：请检查网络/镜像源/远程 images 是否可用"
    echo -e "${YELLOW}建议:${NC}"
    echo "  lxc remote list"
    echo "  lxc image list images: | head"
  fi
  pause
}

# ---- Snapshot / rollback ----
snapshot_menu() {
  ensure_lxc || return
  list_containers || { pause; return; }

  read -r -p "选择容器(名字或编号): " input < /dev/tty
  input="$(sanitize_input "$input")"
  local target=""
  if ! target="$(resolve_target "$input")"; then
    err "编号越界或输入无效。"
    pause
    return
  fi

  echo -e "${BLUE}快照操作:${NC}"
  echo "  1) 创建快照"
  echo "  2) 列出快照"
  echo "  3) 回滚到快照"
  read -r -p "请选择 [1-3]: " op < /dev/tty
  op="$(sanitize_input "$op")"

  case "$op" in
    1)
      local def_sn="snap-$(date +%Y%m%d-%H%M%S)"
      read -r -p "快照名 (默认: $def_sn): " sn < /dev/tty
      sn="$(sanitize_input "${sn:-}")"
      [[ -z "$sn" ]] && sn="$def_sn"
      if lxc snapshot "$target" "$sn"; then ok "快照创建成功：$target/$sn"; else err "快照创建失败"; fi
      ;;
    2)
      lxc info "$target" | sed -n '/^Snapshots:/,$p' || true
      ;;
    3)
      read -r -p "请输入要回滚的快照名: " sn < /dev/tty
      sn="$(sanitize_input "$sn")"
      if [[ -z "$sn" ]]; then err "快照名不能为空"; pause; return; fi
      warn "即将回滚：$target -> $sn（会覆盖当前状态）"
      read -r -p "确认请输入 YES: " c < /dev/tty
      if [[ "$c" == "YES" ]]; then
        if lxc restore "$target" "$sn"; then ok "回滚成功"; else err "回滚失败"; fi
      else
        warn "已取消。"
      fi
      ;;
    *) warn "无效选择";;
  esac

  pause
}

# ---- Resource limits ----
resource_limits() {
  ensure_lxc || return
  list_containers || { pause; return; }

  read -r -p "选择容器(名字或编号): " input < /dev/tty
  input="$(sanitize_input "$input")"
  local target=""
  if ! target="$(resolve_target "$input")"; then
    err "编号越界或输入无效。"
    pause
    return
  fi

  echo -e "${BLUE}资源限制设置（留空=不修改）${NC}"
  read -r -p "CPU 核数限制 (例: 2): " cpu < /dev/tty
  cpu="$(sanitize_input "${cpu:-}")"
  read -r -p "内存限制 (例: 1024MB / 2GB): " mem < /dev/tty
  mem="$(sanitize_input "${mem:-}")"

  if [[ -n "$cpu" ]]; then
    if lxc config set "$target" limits.cpu "$cpu"; then ok "已设置 limits.cpu=$cpu"; else err "设置 CPU 失败"; fi
  fi
  if [[ -n "$mem" ]]; then
    if lxc config set "$target" limits.memory "$mem"; then ok "已设置 limits.memory=$mem"; else err "设置内存失败"; fi
  fi

  echo -e "${YELLOW}当前限制：${NC}"
  lxc config show "$target" | grep -E 'limits\.(cpu|memory)' || echo "  (未设置)"
  pause
}

# ---- Delete container ----
delete_container() {
  ensure_lxc || return
  list_containers || { pause; return; }

  read -r -p "输入名字或编号销毁: " input < /dev/tty
  input="$(sanitize_input "$input")"

  local t=""
  if ! t="$(resolve_target "$input")"; then
    err "编号越界或输入无效。"
    pause
    return
  fi

  warn "将要强制删除容器：$t"
  read -r -p "确认请输入 YES: " confirm < /dev/tty
  if [[ "$confirm" != "YES" ]]; then
    warn "已取消。"
    pause
    return
  fi

  if lxc delete "$t" --force; then
    ok "已删除：$t"
  else
    err "删除失败：$t"
  fi
  pause
}

# ---- Update script (safe) ----
update_script() {
  local dest tmp
  dest="$(safe_script_path_for_update)"
  tmp="$(mktemp)"

  info "从 GitHub 更新脚本..."
  if ! curl -fsSL --retry 3 --retry-delay 1 "$GITHUB_URL" -o "$tmp"; then
    err "下载失败：$GITHUB_URL"
    rm -f "$tmp"
    pause
    return
  fi

  # 防止下载到 HTML 错误页
  if ! head -n 1 "$tmp" | grep -qE '^#!'; then
    err "下载内容不像脚本（缺少 shebang），已取消覆盖。"
    rm -f "$tmp"
    pause
    return
  fi

  install -m 0755 "$tmp" "$dest"
  rm -f "$tmp"
  ok "更新完成：$dest"
  pause
  exec bash "$dest"
}
net_exists() {
  lxc network show "$1" >/dev/null 2>&1
}

detect_lxd_bridge_net() {
  local n=""

  # 1) 常见名字优先
  for n in lxdbr0 lxdbr1 lxdbr2; do
    net_exists "$n" && { echo "$n"; return 0; }
  done

  # 2) 从 default profile 里找 NIC 的 parent/network
  n="$(lxc profile show default 2>/dev/null | awk '
    $1=="network:"{print $2; exit}
    $1=="parent:"{print $2; exit}
  ')"
  [[ -n "$n" ]] && net_exists "$n" && { echo "$n"; return 0; }

  # 3) 从 network list 里找第一个 managed bridge
  n="$(lxc network list -c n,t,m --format csv 2>/dev/null | awk -F',' '
    ($2=="bridge") && (tolower($3)=="yes") {print $1; exit}
  ')"
  [[ -n "$n" ]] && net_exists "$n" && { echo "$n"; return 0; }

  return 1
}

# ---- IPv6 menu ----
ipv6_menu() {
  ensure_lxc || return

  local net="${LXD_BR_NET:-}"
  if [[ -z "$net" ]]; then
    net="$(detect_lxd_bridge_net 2>/dev/null || true)"
  fi

  if [[ -z "$net" ]] || ! net_exists "$net"; then
    err "未找到可用的 LXD bridge 网络（所以才会 Network not found）"
    echo -e "${YELLOW}当前网络列表：${NC}"
    lxc network list || true
    echo
    read -r -p "请输入要管理的网络名（例如 lxdbr0 / lxdbr1 / 你列表里的名字）: " net < /dev/tty
    net="$(sanitize_input "${net:-}")"
    if [[ -z "$net" ]] || ! net_exists "$net"; then
      err "网络名无效或不存在：$net"
      pause
      return
    fi
  fi

  LXD_BR_NET="$net"

  local addr nat fw
  addr="$(lxc network get "$net" ipv6.address 2>/dev/null || echo "<unset>")"
  nat="$(lxc network get "$net" ipv6.nat 2>/dev/null || echo "<unset>")"
  fw="$(lxc network get "$net" ipv6.firewall 2>/dev/null || echo "<unset>")"

  echo -e "${BLUE}IPv6 管理 (${net})${NC}"
  echo -e "当前：ipv6.address=${YELLOW}${addr}${NC}   ipv6.nat=${YELLOW}${nat}${NC}   ipv6.firewall=${YELLOW}${fw}${NC}"
  echo "------------------------------------"
  echo "1) ✅ 开启：仅容器 IPv6 出站 (ULA + NAT66)"
  echo "2) ❌ 关闭：禁用该网络 IPv6"
  echo "3) 🔎 测试某个容器 IPv6 连通"
  echo "0) 返回"
  read -r -p "请选择: " op < /dev/tty
  op="$(sanitize_input "${op:-}")"

  case "$op" in
    1)
      if ! ip -6 route show default | grep -q .; then
        warn "宿主机没有 IPv6 默认路由（ip -6 route default 为空），容器 IPv6 出站可能仍不可用。"
      fi

      if lxc network set "$net" ipv6.address auto \
        && lxc network set "$net" ipv6.nat true \
        && lxc network set "$net" ipv6.firewall true; then
        ok "已开启：${net} -> ULA + NAT66（仅容器出站 IPv6）"
      else
        err "开启失败：请检查 network/project/权限"
        echo -e "${YELLOW}建议：${NC} lxc network show $net"
      fi
      pause
      ;;
    2)
      if lxc network set "$net" ipv6.address none \
        && lxc network set "$net" ipv6.nat false \
        && lxc network set "$net" ipv6.firewall false; then
        ok "已关闭：${net} IPv6"
      else
        err "关闭失败：请检查 network/project/权限"
        echo -e "${YELLOW}建议：${NC} lxc network show $net"
      fi
      pause
      ;;
    3)
      list_containers || { pause; return; }
      read -r -p "选择容器(名字或编号): " input < /dev/tty
      input="$(sanitize_input "$input")"
      local target=""
      if ! target="$(resolve_target "$input")"; then
        err "编号越界或输入无效。"
        pause
        return
      fi
      echo -e "${BLUE}---- $target IPv6 信息 ----${NC}"
      lxc_exec_tty "$target" /bin/sh -lc 'ip -6 addr show; echo; ip -6 route; echo; ping -6 -c 3 2606:4700:4700::1111' || true
      pause
      ;;
    0) return ;;
    *) warn "无效选项"; pause ;;
  esac
}
detect_lxd_install_method() {
  # echo: snap | apt | unknown
  if command -v snap >/dev/null 2>&1 && snap list 2>/dev/null | awk '{print $1}' | grep -qx lxd; then
    echo "snap"; return 0
  fi
  if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Status}' lxd 2>/dev/null | grep -q "installed" && { echo "apt"; return 0; }
  fi
  if command -v rpm >/dev/null 2>&1 && rpm -q lxd >/dev/null 2>&1; then
    echo "rpm"; return 0
  fi
  if command -v apk >/dev/null 2>&1 && apk info -e lxd >/dev/null 2>&1; then
    echo "apk"; return 0
  fi
  if command -v pacman >/dev/null 2>&1 && pacman -Q lxd >/dev/null 2>&1; then
    echo "pacman"; return 0
  fi
  echo "unknown"
}

lxd_data_dirs_for_method() {
  # 输出一行或多行：需要清理的数据目录
  local m="$1"
  case "$m" in
    snap)
      echo "/var/snap/lxd"
      echo "/var/snap/lxd/common/lxd"
      ;;
    apt|rpm|apk|pacman)
      echo "/var/lib/lxd"
      echo "/var/cache/lxd"
      echo "/var/log/lxd"
      echo "/etc/lxd"
      ;;
    *)
      # 尽力列举常见路径
      echo "/var/snap/lxd"
      echo "/var/lib/lxd"
      echo "/etc/lxd"
      ;;
  esac
}

cleanup_lxd_bridges() {
  # 删除残留的 lxdbr* 网桥（不会动你自定义 br0 之类）
  command -v ip >/dev/null 2>&1 || return 0
  local br
  for br in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -E '^lxdbr[0-9]+$' || true); do
    ip link set "$br" down >/dev/null 2>&1 || true
    ip link delete "$br" >/dev/null 2>&1 || true
  done
}

export_all_instances() {
  # 导出所有容器到指定目录（tarball）
  local outdir="$1"
  command -v lxc >/dev/null 2>&1 || { err "找不到 lxc 命令，无法导出。"; return 1; }

  mkdir -p "$outdir" || return 1

  local names=()
  mapfile -t names < <(lxc list -c n --format csv 2>/dev/null | tr -d '\r' | sed '/^$/d')
  if [[ ${#names[@]} -eq 0 ]]; then
    warn "没有容器可导出。"
    return 0
  fi

  info "开始导出 ${#names[@]} 个容器到：$outdir"
  local n okc=0 failc=0
  for n in "${names[@]}"; do
    info "导出: $n -> $outdir/${n}.tar.gz"
    if lxc export "$n" "$outdir/${n}.tar.gz" >/dev/null 2>&1; then
      okc=$((okc+1))
    else
      failc=$((failc+1))
      warn "导出失败：$n（你可手动：lxc export $n ...）"
    fi
  done
  ok "导出完成：成功 $okc / 失败 $failc"
  return 0
}

uninstall_env() {
  # 不强依赖 ensure_lxc：即便 lxc 不可用也能卸载
  need_root

  local method
  method="$(detect_lxd_install_method)"

  echo -e "${RED}⚠️  彻底卸载 LXD/LXC 环境（高危）${NC}"
  echo -e "${YELLOW}将执行：停止服务 -> (可选导出容器) -> 删除所有实例/镜像/网络/存储数据 -> 卸载软件包 -> 清理数据目录${NC}"
  echo

  echo -e "${BLUE}检测到安装方式：${NC} ${YELLOW}${method}${NC}"
  echo -e "${BLUE}可能的数据目录：${NC}"
  lxd_data_dirs_for_method "$method" | sed 's/^/  - /'
  echo

  # 统计信息（能取到就展示）
  if command -v lxc >/dev/null 2>&1; then
    local icount
    icount="$(lxc list -c n --format csv 2>/dev/null | sed '/^$/d' | wc -l | tr -d ' ')"
    echo -e "${BLUE}检测到实例数量：${NC} ${YELLOW}${icount}${NC}"
  fi
  echo

  # 1) 备份导出（可选）
  read -r -p "是否先导出全部容器备份？(y/N): " b < /dev/tty
  b="$(sanitize_input "${b:-}")"
  if [[ "$b" == "y" || "$b" == "Y" ]]; then
    local out="/root/lxd-exports-$(date +%Y%m%d-%H%M%S)"
    read -r -p "导出目录 (默认: $out): " out_in < /dev/tty
    out_in="$(sanitize_input "${out_in:-}")"
    [[ -n "$out_in" ]] && out="$out_in"
    export_all_instances "$out" || warn "导出步骤出现问题，但你仍可继续卸载。"
    echo
  fi

  # 2) 最终强确认
  echo -e "${RED}最后确认：这会删除所有 LXD 数据，且不可恢复。${NC}"
  echo -e "${YELLOW}请输入：UNINSTALL-LXD 继续；输入其它任何内容取消。${NC}"
  read -r -p "确认输入: " confirm < /dev/tty
  confirm="$(sanitize_input "${confirm:-}")"
  if [[ "$confirm" != "UNINSTALL-LXD" ]]; then
    warn "已取消卸载。"
    pause
    return
  fi

  # 3) 停服务 + 尽力删除实例（如果 lxc 可用）
  if command -v lxc >/dev/null 2>&1; then
    info "尝试删除所有实例（容器/虚拟机）..."
    # 停止全部实例
    lxc list -c n --format csv 2>/dev/null | tr -d '\r' | sed '/^$/d' | while read -r n; do
      lxc stop "$n" --force >/dev/null 2>&1 || true
    done
    # 删除全部实例
    lxc list -c n --format csv 2>/dev/null | tr -d '\r' | sed '/^$/d' | while read -r n; do
      lxc delete "$n" --force >/dev/null 2>&1 || true
    done
  fi

  # 4) 卸载软件
  case "$method" in
    snap)
      info "停止并卸载 snap lxd..."
      snap stop lxd >/dev/null 2>&1 || true
      snap remove --purge lxd >/dev/null 2>&1 || true
      ;;
    apt)
      info "停止并卸载 apt lxd..."
      systemctl stop lxd lxd.socket >/dev/null 2>&1 || true
      # lxd/lxc 相关：按“彻底”思路，lxc 与 lxcfs 一并卸载
      DEBIAN_FRONTEND=noninteractive apt-get purge -y lxd lxd-client lxc lxcfs >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
      ;;
    rpm)
      info "停止并卸载 rpm lxd..."
      systemctl stop lxd lxd.socket >/dev/null 2>&1 || true
      yum remove -y lxd lxc lxcfs >/dev/null 2>&1 || dnf remove -y lxd lxc lxcfs >/dev/null 2>&1 || true
      ;;
    apk)
      info "卸载 apk lxd..."
      rc-service lxd stop >/dev/null 2>&1 || true
      apk del lxd lxc lxcfs >/dev/null 2>&1 || true
      ;;
    pacman)
      info "卸载 pacman lxd..."
      systemctl stop lxd lxd.socket >/dev/null 2>&1 || true
      pacman -Rns --noconfirm lxd lxc lxcfs >/dev/null 2>&1 || true
      ;;
    *)
      warn "未识别安装方式，将只做目录清理与网桥清理（你可手动卸载软件包）。"
      ;;
  esac

  # 5) 清理数据目录
  info "清理数据目录..."
  local d
  while read -r d; do
    [[ -z "$d" ]] && continue
    if [[ -e "$d" ]]; then
      rm -rf "$d" >/dev/null 2>&1 || true
    fi
  done < <(lxd_data_dirs_for_method "$method")

  # 6) 清理残留网桥
  info "清理残留 lxdbr* 网桥..."
  cleanup_lxd_bridges

  ok "卸载流程已执行完成。建议重启一次系统以清理残留（可选）。"
  pause
}
# ---- Uninstall (占位：避免误伤系统) ----
uninstall_env() {
  warn "彻底卸载环境属于高危操作（不同发行版安装方式不同：snap lxd / apt lxd / 自编译）。"
  echo -e "${YELLOW}请告诉我你是怎么装的：${NC}"
  echo "  - Ubuntu + snap lxd？"
  echo "  - apt 安装？"
  echo "  - 还是 Proxmox/LXC？"
  echo "我再给你生成对应的“可回滚卸载脚本”。"
  pause
}

# ---- Main menu ----
main_menu() {
  while true; do
    clear
    echo -e "${BLUE}====================================${NC}"
    echo -e "${GREEN}      sockc LXC 极客面板 v5.2       ${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo -e "1. 🏗️  创建新容器"
    echo -e "2. 📸  快照备份 / 一键回滚"
    echo -e "3. 🚪  ${GREEN}进入指定容器 (稳健驻留版)${NC}"
    echo -e "4. 🌐  IPv6 独立管理 (开关)  ${YELLOW}"
    echo -e "5. 📋  容器列表 & 状态查看"
    echo -e "6. ⚙️  资源限制修改"
    echo -e "7. 🗑️  销毁指定容器"
    echo -e "8. 🔄  从 GitHub 更新脚本"
    echo -e "9. ❌  彻底卸载环境  ${YELLOW}"
    echo -e "0. 退出脚本"
    echo -e "${BLUE}------------------------------------${NC}"

    read -r -p "请输入指令: " opt < /dev/tty
    opt="$(sanitize_input "${opt:-}")"

    case "$opt" in
      1) create_container ;;
      2) snapshot_menu ;;
      3) enter_container ;;
      4) ipv6_menu ;;
      5) ensure_lxc && lxc list; pause ;;
      6) resource_limits ;;
      7) delete_container ;;
      8) update_script ;;
      9) uninstall_env ;;
      0) exit 0 ;;
      *) warn "无效选项：$opt"; pause ;;
    esac
  done
}

need_root
main_menu
