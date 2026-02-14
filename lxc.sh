#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.2)
# 修复: 彻底解决菜单刷新 Bug，加入 IPv6 与 自动更新
# 架构: 支持 ARM64 / x86_64
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
# 替换为你真实的 GitHub Raw 链接
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/lxc.sh"

# --- 1. 快捷入口与更新逻辑 ---
init_shortcut() {
    if [[ -f "$SCRIPT_PATH" ]]; then
        if ! grep -q "alias lxc-mgr=" ~/.bashrc; then
            echo "alias lxc-mgr='bash $SCRIPT_PATH'" >> ~/.bashrc
            export SHORTCUT_ADDED=1
        fi
    fi
}

update_script() {
    echo -e "${BLUE}🔄 正在从 GitHub 获取最新版本...${NC}"
    if curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH.tmp"; then
        mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"
        chmod +x "$SCRIPT_PATH"
        echo -e "${GREEN}✅ 更新成功！正在重启脚本...${NC}"
        sleep 1
        exec bash "$SCRIPT_PATH"
    else
        echo -e "${RED}❌ 更新失败，请检查网络或 GitHub 链接是否正确。${NC}"
        sleep 2
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

manage_ipv6() {
    list_containers || return
    read -p "选择要操作的容器编号: " idx < /dev/tty
    local target="${containers[$idx]}"
    echo -e "1. ${GREEN}开启${NC} 独立公网 IPv6\n2. ${RED}关闭${NC} IPv6 (仅保留 IPv4)"
    read -p "请选择: " v6_opt < /dev/tty
    if [[ "$v6_opt" == "1" ]]; then
        lxc config device unset "$target" eth0 ipv6.address
        echo -e "${GREEN}✅ $target 已开启 IPv6 自动获取。${NC}"
    else
        lxc config device set "$target" eth0 ipv6.address none
        echo -e "${YELLOW}🚫 $target 已禁用 IPv6。${NC}"
    fi
    sleep 2
}

# --- 3. 主菜单 (使用 while 循环 + clear 保持置顶) ---
main_menu() {
    init_shortcut
    
    while true; do
        clear  # 保证菜单始终在顶部
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.2       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 创建新容器 (自定义命名/限额)"
        echo -e "2. 快照管理 (一键备份/回滚状态)"
        echo -e "3. 容器列表 & 实时状态查看"
        echo -e "4. ${BLUE}IPv6 独立管理 (开启/关闭独立IP)${NC}"
        echo -e "5. 修改现有容器资源限额 (CPU/内存)"
        echo -e "6. 销毁指定容器"
        echo -e "7. ${YELLOW}检查并强制更新脚本 (GitHub)${NC}"
        echo -e "8. ${RED}彻底卸载环境 (清空所有数据)${NC}"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"
        
        [[ "$SHORTCUT_ADDED" == "1" ]] && echo -e "${YELLOW}提示: 请运行 'source ~/.bashrc' 激活 lxc-mgr${NC}"

        read -p "请输入指令 [0-8]: " opt < /dev/tty
        
        case $opt in
            1) 
                read -p "容器名称: " cname < /dev/tty
                cname=${cname:-test-$(date +%s)}
                lxc launch images:ubuntu/24.04 "$cname"
                read -p "限制内存 (如 512MB, 直接回车跳过): " mem < /dev/tty
                [[ -n "$mem" ]] && lxc config set "$cname" limits.memory "$mem"
                ;;
            2)
                list_containers && {
                    read -p "选择编号: " idx < /dev/tty
                    target="${containers[$idx]}"
                    echo -e "1.拍快照 2.回滚"
                    read -p "选择: " s_opt < /dev/tty
                    [[ "$s_opt" == "1" ]] && { read -p "快照名: " sn < /dev/tty; lxc snapshot "$target" "$sn"; }
                    [[ "$s_opt" == "2" ]] && { read -p "回滚名: " rn < /dev/tty; lxc restore "$target" "$rn"; }
                }
                ;;
            3) lxc list; read -p "按回车继续..." < /dev/tty ;;
            4) manage_ipv6 ;;
            5)
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    read -p "新内存限额 (如 1GB): " m < /dev/tty
                    lxc config set "${containers[$idx]}" limits.memory "$m"
                }
                ;;
            6) 
                list_containers && {
                    read -p "输入编号销毁: " d_idx < /dev/tty
                    lxc delete "${containers[$d_idx]}" --force
                }
                ;;
            7) update_script ;;
            8)
                read -p "确定彻底卸载吗? (y/n): " confirm < /dev/tty
                if [[ "$confirm" == "y" ]]; then
                    lxc delete $(lxc list -c n --format csv) --force 2>/dev/null || true
                    sed -i '/alias lxc-mgr=/d' ~/.bashrc
                    sudo apt purge -y lxd lxd-client && sudo apt autoremove -y
                    echo "卸载完成。"
                    exit 0
                fi
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}无效输入!${NC}"; sleep 1 ;;
        esac
    done
}

# 权限检查并启动
[[ $EUID -ne 0 ]] && echo "请使用 root 运行" && exit 1
main_menu
