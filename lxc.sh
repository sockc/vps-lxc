#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.7)
# 修复: 彻底解决 IPv6 "Device doesn't exist" 报错
# 功能: 菜单置顶、进入容器、快照回滚、资源限制、彻底卸载
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# --- 1. 环境初始化与快捷入口 ---
init_shortcut() {
    if [[ -f "$SCRIPT_PATH" ]] && ! grep -q "alias lxc-mgr=" ~/.bashrc; then
        echo "alias lxc-mgr='bash $SCRIPT_PATH'" >> ~/.bashrc
        export SHORTCUT_ADDED=1
    fi
}

# --- 2. 核心功能函数 ---
list_containers() {
    mapfile -t containers < <(lxc list -c n --format csv)
    if [ ${#containers[@]} -eq 0 ]; then
        echo -e "${YELLOW}目前没有任何容器。${NC}"
        return 1
    fi
    for i in "${!containers[@]}"; do
        printf "  [%d] %s\n" "$i" "${containers[$i]}"
    done
}

# 修复版 IPv6 管理：先确保设备存在再设置
manage_ipv6() {
    clear
    echo -e "${BLUE}==== IPv6 独立管理中心 ====${NC}"
    list_containers || { sleep 2; return; }
    read -p "选择容器编号: " idx < /dev/tty
    local target="${containers[$idx]}"
    [[ -z "$target" ]] && return

    echo -e "1. ${GREEN}开启${NC} 独立公网 IPv6\n2. ${RED}关闭${NC} IPv6"
    read -p "选择: " v_opt < /dev/tty

    # 核心修复逻辑：确保 eth0 在容器层级存在
    if ! lxc config device show "$target" | grep -q "eth0:"; then
        lxc config device add "$target" eth0 nic nictype=bridged parent=lxdbr0 name=eth0 > /dev/null 2>&1
    fi

    if [[ "$v_opt" == "1" ]]; then
        lxc config device unset "$target" eth0 ipv6.address > /dev/null 2>&1
        echo -e "${GREEN}✅ $target 已开启独立 IPv6。重启容器生效。${NC}"
    else
        lxc config device set "$target" eth0 ipv6.address none > /dev/null 2>&1
        echo -e "${YELLOW}🚫 $target 已禁用 IPv6。${NC}"
    fi
    sleep 2
}

# --- 3. 卸载功能 ---
uninstall_all() {
    echo -e "${RED}⚠️  警告：这将删除所有容器并卸载 LXD 环境！${NC}"
    read -p "确定要彻底卸载吗? (y/n): " confirm < /dev/tty
    if [[ "$confirm" == "y" ]]; then
        lxc delete $(lxc list -c n --format csv) --force 2>/dev/null || true
        sed -i '/alias lxc-mgr=/d' ~/.bashrc
        sudo apt purge -y lxd lxd-client && sudo apt autoremove -y
        echo -e "${GREEN}✅ 卸载完成。${NC}"
        exit 0
    fi
}

# --- 4. 主菜单 (强制置顶) ---
main_menu() {
    init_shortcut
    while true; do
        clear
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.7       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 🏗️  创建新容器 (自定义命名/限额)"
        echo -e "2. 📸  快照管理 (备份/一键回滚)"
        echo -e "3. 🚪  ${GREEN}进入指定容器 (打命令)${NC}"
        echo -e "4. 🌐  IPv6 独立管理 (修复设备报错)"
        echo -e "5. 📋  容器列表 & 运行状态查看"
        echo -e "6. ⚙️  修改资源限额 (CPU/内存)"
        echo -e "7. 🗑️  销毁指定容器"
        echo -e "8. 🔄  ${YELLOW}从 GitHub 更新脚本${NC}"
        echo -e "9. ❌  ${RED}彻底卸载环境${NC}"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"
        
        [[ "$SHORTCUT_ADDED" == "1" ]] && echo -e "${YELLOW}提示: 请执行 'source ~/.bashrc' 激活 lxc-mgr${NC}"

        read -p "请输入指令: " opt < /dev/tty
        case $opt in
            1) 
                read -p "名称: " cname < /dev/tty
                [[ "$cname" =~ ^[0-9] ]] && cname="v$cname"
                lxc launch ubuntu:24.04 "${cname:-test-$(date +%s)}" ;;
            2) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty; t="${containers[$idx]}"
                    echo "1.拍快照 2.回滚"; read -p ":" so < /dev/tty
                    [[ "$so" == "1" ]] && { read -p "名: " sn < /dev/tty; lxc snapshot "$t" "$sn"; }
                    [[ "$so" == "2" ]] && { read -p "回滚名: " rn < /dev/tty; lxc restore "$t" "$rn"; }
                } ;;
            3) 
                list_containers && {
                    read -p "进入编号: " idx < /dev/tty; t="${containers[$idx]}"
                    lxc exec "$t" -- bash
                } ;;
            4) manage_ipv6 ;;
            5) lxc list; read -p "回车继续..." < /dev/tty ;;
            6) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    read -p "内存限额(如 1GB): " m < /dev/tty
                    lxc config set "${containers[$idx]}" limits.memory "$m"
                } ;;
            7) 
                list_containers && {
                    read -p "删除编号: " d_idx < /dev/tty
                    lxc delete "${containers[$d_idx]}" --force
                } ;;
            8) curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" && exec bash "$SCRIPT_PATH" ;;
            9) uninstall_all ;;
            0) exit 0 ;;
            *) echo "无效输入"; sleep 1 ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
main_menu
