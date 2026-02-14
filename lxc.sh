#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.3)
# 修复: 解决了 Ubuntu 24.04 镜像找不到的问题
# 功能: 菜单置顶、IPv6 独立开关、资源限制、一键更新
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

SCRIPT_PATH=$(readlink -f "$0")
GITHUB_URL="https://raw.githubusercontent.com/sockc/vps-lxc/main/pro.sh"

# --- 1. 自动设置快捷入口 ---
init_shortcut() {
    if [[ -f "$SCRIPT_PATH" ]]; then
        if ! grep -q "alias lxc-mgr=" ~/.bashrc; then
            echo "alias lxc-mgr='bash $SCRIPT_PATH'" >> ~/.bashrc
            export SHORTCUT_ADDED=1
        fi
    fi
}

# --- 2. 核心功能 ---
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

create_container() {
    read -p "请输入容器名称: " cname < /dev/tty
    cname=${cname:-test-$(date +%s)}
    
    echo -e "选择系统:"
    echo "1. Ubuntu 24.04 (官方源)"
    echo "2. Debian 12 (社区源)"
    echo "3. Alpine (极简)"
    read -p "请选择: " img_num < /dev/tty
    
    case $img_num in
        2) img="images:debian/12" ;;
        3) img="images:alpine/latest" ;;
        *) img="ubuntu:24.04" ;; # 修复：改用官方 ubuntu: 库
    esac

    echo -e "${BLUE}正在拉取镜像并创建容器...${NC}"
    if lxc launch "$img" "$cname"; then
        read -p "限制内存 (如 512MB, 回车跳过): " mem < /dev/tty
        [[ -n "$mem" ]] && lxc config set "$cname" limits.memory "$mem"
        echo -e "${GREEN}✅ 容器 $cname 创建成功！${NC}"
    else
        echo -e "${RED}❌ 创建失败，请检查网络或镜像名。${NC}"
    fi
    sleep 2
}

manage_ipv6() {
    list_containers || { sleep 2; return; }
    read -p "请选择容器编号进行 IPv6 管理: " idx < /dev/tty
    local target="${containers[$idx]}"
    [[ -z "$target" ]] && return

    echo -e "1. ${GREEN}开启${NC} 独立公网 IPv6\n2. ${RED}关闭${NC} IPv6"
    read -p "选择 [1-2]: " v_opt < /dev/tty
    if [[ "$v_opt" == "1" ]]; then
        lxc config device unset "$target" eth0 ipv6.address
        echo -e "${GREEN}✅ 已开启。容器重启后将自动获取公网 IPv6。${NC}"
    else
        lxc config device set "$target" eth0 ipv6.address none
        echo -e "${YELLOW}🚫 已禁用 IPv6。${NC}"
    fi
    sleep 2
}

# --- 3. 主菜单 (强制置顶) ---
main_menu() {
    init_shortcut
    while true; do
        clear  # 确保菜单永远在终端顶部
        echo -e "${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.3       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo -e "1. 🏗️  创建新容器 (修复 Ubuntu 24.04)"
        echo -e "2. 📸  快照管理 (备份与一键回滚)"
        echo -e "3. 📋  容器列表 & 运行状态查看"
        echo -e "4. 🌐  ${BLUE}IPv6 独立开关管理 (核心功能)${NC}"
        echo -e "5. ⚙️  修改容器资源限额 (CPU/内存)"
        echo -e "6. 🗑️  销毁指定容器"
        echo -e "7. 🔄  ${YELLOW}从 GitHub 强制更新脚本${NC}"
        echo -e "8. ❌  卸载环境"
        echo -e "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"
        
        [[ "$SHORTCUT_ADDED" == "1" ]] && echo -e "${YELLOW}提示: 请执行 'source ~/.bashrc' 激活 lxc-mgr 命令${NC}"

        read -p "请输入选项: " opt < /dev/tty
        case $opt in
            1) create_container ;;
            2) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    t="${containers[$idx]}"
                    echo "1.拍快照 2.回滚"; read -p ":" so < /dev/tty
                    [[ "$so" == "1" ]] && { read -p "快照名: " sn < /dev/tty; lxc snapshot "$t" "$sn"; }
                    [[ "$so" == "2" ]] && { read -p "回滚名: " rn < /dev/tty; lxc restore "$t" "$rn"; }
                } ;;
            3) lxc list; read -p "按回车继续..." < /dev/tty ;;
            4) manage_ipv6 ;;
            5) 
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    read -p "新内存 (如 1GB): " m < /dev/tty
                    lxc config set "${containers[$idx]}" limits.memory "$m"
                } ;;
            6) 
                list_containers && {
                    read -p "输入编号删除: " d_idx < /dev/tty
                    lxc delete "${containers[$d_idx]}" --force
                } ;;
            7) 
                echo "正在更新..."
                curl -fsSL "$GITHUB_URL" -o "$SCRIPT_PATH" && chmod +x "$SCRIPT_PATH" && exec bash "$SCRIPT_PATH"
                ;;
            8) 
                read -p "确定卸载? (y/n): " cf < /dev/tty
                [[ "$cf" == "y" ]] && { lxc delete $(lxc list -c n --format csv) --force; apt purge -y lxd; exit; } ;;
            0) exit 0 ;;
            *) echo "无效选择"; sleep 1 ;;
        esac
    done
}

[[ $EUID -ne 0 ]] && echo "请用 root 运行" && exit 1
main_menu
