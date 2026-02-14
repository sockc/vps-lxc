#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v5.0)
# 修复: 解决了进入容器失败自动跳回主菜单的 Bug
# 功能: 报错拦截、双 Shell 支持、输入清洗、状态自愈
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# --- 1. 列表显示 ---
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

# --- 2. 核心：带报错拦截的进入函数 ---
enter_container() {
    list_containers || { sleep 1; return; }
    echo -e "${YELLOW}提示: 直接输入名字 v1 最准${NC}"
    read -p "请输入名字或编号: " input < /dev/tty
    
    # 清洗输入：去掉空格
    input=$(echo $input | tr -d ' ')
    
    local target=""
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        target="${containers[$input]}"
    else
        target="$input"
    fi

    [[ -z "$target" ]] && echo -e "${RED}❌ 输入不能为空！${NC}" && sleep 1 && return

    # 状态检查
    local status=$(lxc info "$target" 2>/dev/null | grep "Status:" | awk '{print $2}')
    if [ -z "$status" ]; then
        echo -e "${RED}❌ 找不到容器 '$target'，请确认名字是否拼错。${NC}"
        read -p "按回车继续..." < /dev/tty
        return
    fi

    if [[ "$status" != "RUNNING" ]]; then
        echo -e "${YELLOW}提示: $target 当前处于 $status 状态，尝试启动...${NC}"
        lxc start "$target" && sleep 3
    fi

    echo -e "${GREEN}🚀 正在尝试连接 $target ...${NC}"
    
    # 双 Shell 尝试逻辑
    # 先试 bash，不行再试 sh。如果都失败，捕获错误信息。
    if ! lxc exec "$target" -- bash; then
        echo -e "${YELLOW}⚠️  无法开启 bash，尝试使用 /bin/sh 进入...${NC}"
        if ! lxc exec "$target" -- sh; then
            echo -e "${RED}------------------------------------${NC}"
            echo -e "${RED}❌ 致命错误: 无法进入容器 '$target'${NC}"
            echo -e "${YELLOW}可能原因:${NC}"
            echo "  1. 容器初始化未完成"
            echo "  2. 宿主机与容器的 TTY 通讯异常"
            echo "  3. 容器内部文件系统损坏"
            echo -e "${RED}------------------------------------${NC}"
            read -p "请仔细阅读上方报错，按回车键返回主菜单..." < /dev/tty
        fi
    fi
}

# --- 3. 主菜单 (保留 clear) ---
main_menu() {
    while true; do
        clear
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v5.0       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 🏗️  创建新容器"
        echo -e "2. 📸  快照备份 / 一键回滚"
        echo -e "3. 🚪  ${GREEN}进入指定容器 (报错驻留版)${NC}"
        echo -e "4. 🌐  IPv6 独立管理 (开关)"
        echo -e "5. 📋  容器列表 & 状态查看"
        echo -e "6. ⚙️  资源限制修改"
        echo -e "7. 🗑️  销毁指定容器"
        echo -e "8. 🔄  从 GitHub 更新脚本"
        echo -e "9. ❌  彻底卸载环境"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"

        read -p "请输入指令: " opt < /dev/tty
        case $opt in
            1) # 创建逻辑...
               ;;
            2) # 快照逻辑...
               ;;
            3) enter_container ;; # 重点测试这个
            4) # IPv6 逻辑...
               ;;
            5) lxc list; read -p "按回车继续..." < /dev/tty ;;
            7) 
                list_containers && {
                    read -p "输入名字或编号销毁: " input < /dev/tty
                    input=$(echo $input | tr -d ' ')
                    [[ "$input" =~ ^[0-9]+$ ]] && t="${containers[$input]}" || t="$input"
                    lxc delete "$t" --force
                } ;;
            8) curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH" && exec bash "$SCRIPT_PATH" ;;
            0) exit 0 ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
main_menu
