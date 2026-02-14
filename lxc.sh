#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.8)
# 修复: 解决了容器未启动时无法进入的问题 (自动开机)
# 功能: 菜单置顶、智能进入、IPv6 修复、一键更新
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# --- 1. 基础功能 ---
list_containers() {
    mapfile -t containers < <(lxc list -c n --format csv)
    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${YELLOW}目前没有任何容器。${NC}"
        return 1
    fi
    echo -e "${BLUE}现有容器列表:${NC}"
    for i in "${!containers[@]}"; do
        # 获取状态
        status=$(lxc info "${containers[$i]}" | grep "Status:" | awk '{print $2}')
        printf "  [%d] %-15s (%s)\n" "$i" "${containers[$i]}" "$status"
    done
}

# --- 2. 核心修复：智能进入容器 ---
enter_container() {
    list_containers || { sleep 1; return; }
    read -p "请输入要进入的容器编号: " idx < /dev/tty
    local target="${containers[$idx]}"
    
    if [[ -z "$target" ]]; then
        echo -e "${RED}❌ 编号无效。${NC}"
        sleep 1 && return
    fi

    # 检查容器状态
    local status=$(lxc info "$target" | grep "Status:" | awk '{print $2}')
    
    if [[ "$status" != "RUNNING" ]]; then
        echo -e "${YELLOW}提示: 容器 $target 当前处于 $status 状态。${NC}"
        read -p "是否现在启动并进入? (y/n): " start_opt < /dev/tty
        if [[ "$start_opt" == "y" ]]; then
            echo -e "${BLUE}正在启动 $target ...${NC}"
            lxc start "$target"
            sleep 3 # 给系统一点启动时间
        else
            return
        fi
    fi

    echo -e "${GREEN}正在进入容器: $target (输入 exit 退出)${NC}"
    lxc exec "$target" -- bash
}

# --- 3. IPv6 管理 (保持修复状态) ---
manage_ipv6() {
    clear
    echo -e "${BLUE}==== IPv6 独立管理中心 ====${NC}"
    list_containers || { sleep 1; return; }
    read -p "选择编号: " idx < /dev/tty
    local target="${containers[$idx]}"
    [[ -z "$target" ]] && return

    echo -e "1. ${GREEN}开启${NC} 独立公网 IPv6\n2. ${RED}关闭${NC} IPv6"
    read -p "选择: " v_opt < /dev/tty

    # 确保设备定义存在
    if ! lxc config device show "$target" | grep -q "eth0:"; then
        lxc config device add "$target" eth0 nic nictype=bridged parent=lxdbr0 name=eth0 > /dev/null 2>&1
    fi

    if [[ "$v_opt" == "1" ]]; then
        lxc config device unset "$target" eth0 ipv6.address > /dev/null 2>&1
        echo -e "${GREEN}✅ IPv6 已开启。${NC}"
    else
        lxc config device set "$target" eth0 ipv6.address none > /dev/null 2>&1
        echo -e "${YELLOW}🚫 IPv6 已禁用。${NC}"
    fi
    sleep 2
}

# --- 4. 主菜单 (强制置顶) ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.8       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 🏗️  创建新容器 (Ubuntu 24.04)"
        echo -e "2. 📸  快照管理 (备份/回滚)"
        echo -e "3. 🚪  ${GREEN}进入指定容器 (智能开机)${NC}"
        echo -e "4. 🌐  IPv6 独立管理 (开关)"
        echo -e "5. 📋  容器列表 & 状态查看"
        echo -e "6. ⚙️  修改资源限额 (内存)"
        echo -e "7. 🗑️  销毁指定容器"
        echo -e "8. 🔄  ${YELLOW}从 GitHub 更新脚本${NC}"
        echo -e "9. ❌  ${RED}彻底卸载环境${NC}"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"

        read -p "请输入指令: " opt < /dev/tty
        case $opt in
            1) 
                read -p "名称: " cn < /dev/tty
                [[ "$cn" =~ ^[0-9] ]] && cn="v$cn"
                lxc launch ubuntu:24.04 "${cn:-test-$(date +%s)}"
                sleep 2 ;;
            2) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty; t="${containers[$idx]}"
                    echo "1.拍快照 2.回滚"; read -p ":" so < /dev/tty
                    [[ "$so" == "1" ]] && { read -p "名: " sn < /dev/tty; lxc snapshot "$t" "$sn"; }
                    [[ "$so" == "2" ]] && { read -p "回滚名: " rn < /dev/tty; lxc restore "$t" "$rn"; }
                } ;;
            3) enter_container ;; # 调用修复后的函数
            4) manage_ipv6 ;;
            5) lxc list; read -p "回车继续..." < /dev/tty ;;
            6) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    read -p "内存(如 1GB): " m < /dev/tty
                    lxc config set "${containers[$idx]}" limits.memory "$m"
                } ;;
            7) 
                list_containers && {
                    read -p "删除编号: " d_idx < /dev/tty
                    lxc delete "${containers[$d_idx]}" --force
                } ;;
            8) curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" && exec bash "$SCRIPT_PATH" ;;
            9) 
                read -p "确定卸载? (y/n): " cf < /dev/tty
                [[ "$cf" == "y" ]] && { lxc delete $(lxc list -c n --format csv) --force; apt purge -y lxd; exit; } ;;
            0) exit 0 ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
main_menu
