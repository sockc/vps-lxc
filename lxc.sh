#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.9)
# 修复: 兼容“编号”与“名字”输入，防止误输入跳回主菜单
# 功能: 智能识别输入、自动开机、IPv6 修复、资源限制
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# --- 1. 列表显示 (带状态) ---
list_containers() {
    mapfile -t containers < <(lxc list -c n --format csv)
    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${YELLOW}目前没有任何容器。${NC}"
        return 1
    fi
    echo -e "${BLUE}现有容器列表:${NC}"
    for i in "${!containers[@]}"; do
        status=$(lxc info "${containers[$i]}" 2>/dev/null | grep "Status:" | awk '{print $2}')
        printf "  [%d] %-15s (%s)\n" "$i" "${containers[$i]}" "$status"
    done
}

# --- 2. 核心修复：智能识别进入 ---
enter_container() {
    list_containers || { sleep 1; return; }
    echo -e "${YELLOW}提示: 你可以输入左侧编号 [0] 或直接输入名字 v1${NC}"
    read -p "请输入编号或名字: " input < /dev/tty
    
    local target=""
    # 判断输入的是数字还是名字
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        target="${containers[$input]}"
    else
        target="$input"
    fi

    # 验证容器是否存在
    if ! lxc info "$target" >/dev/null 2>&1; then
        echo -e "${RED}❌ 错误: 找不到名为 '$target' 的容器。${NC}"
        read -p "按回车继续..." < /dev/tty
        return
    fi

    # 自动开机检查
    local status=$(lxc info "$target" | grep "Status:" | awk '{print $2}')
    if [[ "$status" != "RUNNING" ]]; then
        echo -e "${YELLOW}提示: $target 当前处于 $status 状态。${NC}"
        read -p "是否启动并进入? (y/n): " start_opt < /dev/tty
        [[ "$start_opt" == "y" ]] && lxc start "$target" && sleep 3
    fi

    echo -e "${GREEN}🚀 正在进入 $target ... (输入 exit 退出)${NC}"
    lxc exec "$target" -- bash
}

# --- 3. IPv6 管理 (稳如泰山版) ---
manage_ipv6() {
    clear
    echo -e "${BLUE}==== IPv6 独立管理中心 ====${NC}"
    list_containers || { sleep 1; return; }
    read -p "输入编号或名字进行操作: " input < /dev/tty
    
    local target=""
    [[ "$input" =~ ^[0-9]+$ ]] && target="${containers[$input]}" || target="$input"
    [[ -z "$target" ]] && return

    # 确保设备存在并开启/关闭
    if ! lxc config device show "$target" | grep -q "eth0:"; then
        lxc config device add "$target" eth0 nic nictype=bridged parent=lxdbr0 name=eth0 > /dev/null 2>&1
    fi

    echo -e "1. ${GREEN}开启${NC} IPv6  2. ${RED}关闭${NC} IPv6"
    read -p "选择: " v_opt < /dev/tty
    if [[ "$v_opt" == "1" ]]; then
        lxc config device unset "$target" eth0 ipv6.address > /dev/null 2>&1
        echo -e "${GREEN}✅ IPv6 开启成功。${NC}"
    else
        lxc config device set "$target" eth0 ipv6.address none > /dev/null 2>&1
        echo -e "${YELLOW}🚫 IPv6 已禁用。${NC}"
    fi
    sleep 2
}

# --- 4. 主菜单 ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.9       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 🏗️  创建新容器"
        echo -e "2. 📸  快照备份 / 一键回滚"
        echo -e "3. 🚪  ${GREEN}进入容器 (支持编号/名字)${NC}"
        echo -e "4. 🌐  IPv6 独立开关"
        echo -e "5. 📋  容器列表 & 状态查看"
        echo -e "6. ⚙️  内存/资源限额修改"
        echo -e "7. 🗑️  销毁指定容器"
        echo -e "8. 🔄  从 GitHub 更新脚本"
        echo -e "9. ❌  彻底卸载环境"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"

        read -p "请输入指令: " opt < /dev/tty
        case $opt in
            1) 
                read -p "名称: " cn < /dev/tty; [[ "$cn" =~ ^[0-9] ]] && cn="v$cn"
                lxc launch ubuntu:24.04 "${cn:-test-$(date +%s)}"
                sleep 2 ;;
            2) 
                list_containers && {
                    read -p "编号或名字: " input < /dev/tty
                    [[ "$input" =~ ^[0-9]+$ ]] && t="${containers[$input]}" || t="$input"
                    echo "1.快照 2.回滚"; read -p ":" so < /dev/tty
                    [[ "$so" == "1" ]] && { read -p "名: " sn < /dev/tty; lxc snapshot "$t" "$sn"; }
                    [[ "$so" == "2" ]] && { read -p "回滚名: " rn < /dev/tty; lxc restore "$t" "$rn"; }
                } ;;
            3) enter_container ;;
            4) manage_ipv6 ;;
            5) lxc list; read -p "按回车继续..." < /dev/tty ;;
            6) 
                list_containers && {
                    read -p "编号或名字: " input < /dev/tty
                    [[ "$input" =~ ^[0-9]+$ ]] && t="${containers[$input]}" || t="$input"
                    read -p "新内存(如 512MB): " m < /dev/tty
                    lxc config set "$t" limits.memory "$m"
                } ;;
            7) 
                list_containers && {
                    read -p "编号或名字销毁: " input < /dev/tty
                    [[ "$input" =~ ^[0-9]+$ ]] && t="${containers[$input]}" || t="$input"
                    lxc delete "$t" --force
                } ;;
            8) curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" && exec bash "$SCRIPT_PATH" ;;
            9) # 卸载逻辑...
               ;;
            0) exit 0 ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
main_menu
