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

# ---- Create container (基础可用版) ----
create_container() {
  ensure_lxc || return

  echo -e "${BLUE}常用镜像示例:${NC}"
  echo "  1) images:ubuntu/24.04"
  echo "  2) images:debian/12"
  echo "  3) images:alpine/3.19"
  echo "  4) 自定义输入"
  read -r -p "选择镜像 [1-4] (默认 1): " ch < /dev/tty
  ch="$(sanitize_input "${ch:-}")"
  local image="images:ubuntu/24.04"
  case "${ch:-1}" in
    1|"") image="images:ubuntu/24.04" ;;
    2) image="images:debian/12" ;;
    3) image="images:alpine/3.19" ;;
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

# ---- IPv6 menu (占位：避免菜单无反应) ----
ipv6_menu() {
  ensure_lxc || return

  local addr nat fw
  addr="$(lxc network get lxdbr0 ipv6.address 2>/dev/null || echo "")"
  nat="$(lxc network get lxdbr0 ipv6.nat 2>/dev/null || echo "")"
  fw="$(lxc network get lxdbr0 ipv6.firewall 2>/dev/null || echo "")"

  echo -e "${BLUE}IPv6 管理 (lxdbr0)${NC}"
  echo -e "当前：ipv6.address=${YELLOW}${addr:-<unset>} ${NC}  ipv6.nat=${YELLOW}${nat:-<unset>} ${NC}  ipv6.firewall=${YELLOW}${fw:-<unset>} ${NC}"
  echo "------------------------------------"
  echo "1) ✅ 开启：仅容器 IPv6 出站 (ULA + NAT66)"
  echo "2) ❌ 关闭：禁用 lxdbr0 IPv6"
  echo "3) 🔎 测试某个容器 IPv6 连通"
  echo "0) 返回"
  read -r -p "请选择: " op < /dev/tty
  op="$(sanitize_input "${op:-}")"

  case "$op" in
    1)
      # 宿主机没有 IPv6 出口时，NAT66 没意义，提前提醒
      if ! ip -6 route show default | grep -q .; then
        echo -e "${YELLOW}⚠️  检测不到宿主机 IPv6 默认路由（ip -6 route default 为空）${NC}"
        echo -e "${YELLOW}   开了 NAT66 容器也可能无法访问 IPv6。${NC}"
      fi
      lxc network set lxdbr0 ipv6.address auto
      lxc network set lxdbr0 ipv6.nat true
      lxc network set lxdbr0 ipv6.firewall true
      echo -e "${GREEN}✅ 已开启：ULA + NAT66（仅容器出站 IPv6）${NC}"
      pause
      ;;
    2)
      lxc network set lxdbr0 ipv6.address none
      lxc network set lxdbr0 ipv6.nat false
      lxc network set lxdbr0 ipv6.firewall false
      echo -e "${GREEN}✅ 已关闭：lxdbr0 IPv6${NC}"
      pause
      ;;
    3)
      list_containers || { pause; return; }
      read -r -p "选择容器(名字或编号): " input < /dev/tty
      input="$(sanitize_input "$input")"
      local target=""
      if ! target="$(resolve_target "$input")"; then
        echo -e "${RED}❌ 编号越界或输入无效。${NC}"
        pause
        return
      fi
      echo -e "${BLUE}---- $target IPv6 信息 ----${NC}"
      lxc exec "$target" -- sh -lc 'ip -6 addr show dev eth0; echo; ip -6 route; echo; ping -6 -c 3 2606:4700:4700::1111' || true
      pause
      ;;
    0) return ;;
    *) echo -e "${YELLOW}无效选项${NC}"; pause ;;
  esac
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
    echo -e "4. 🌐  IPv6 独立管理 (开关)  ${YELLOW}(占位可定制)${NC}"
    echo -e "5. 📋  容器列表 & 状态查看"
    echo -e "6. ⚙️  资源限制修改"
    echo -e "7. 🗑️  销毁指定容器"
    echo -e "8. 🔄  从 GitHub 更新脚本"
    echo -e "9. ❌  彻底卸载环境  ${YELLOW}(占位可定制)${NC}"
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
