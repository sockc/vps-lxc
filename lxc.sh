#!/bin/bash

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# 获取脚本绝对路径
SCRIPT_PATH=$(readlink -f "$0")

# --- 1. 快捷入口设置 ---
init_shortcut() {
    # 只有当脚本是以文件形式存在时才设置 alias
    if [[ -f "$SCRIPT_PATH" ]]; then
        if ! grep -q "alias lxc-mgr=" ~/.bashrc; then
            echo "alias lxc-mgr='bash $SCRIPT_PATH'" >> ~/.bashrc
            export SHORTCUT_ADDED=1
        fi
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

create_container() {
    read -p "请输入容器名称: " cname < /dev/tty
    cname=${cname:-test-$(date +%s)}
    echo -e "选择系统: 1.Ubuntu 24.04  2.Debian 12  3.Alpine"
    read -p "请选择: " img_num < /dev/tty
    case $img_num in
        2) img="images:debian/12" ;;
        3) img="images:alpine/latest" ;;
        *) img="images:ubuntu/24.04" ;;
    esac
    lxc launch "$img" "$cname"
    echo -e "${BLUE}配置限额 (回车跳过):${NC}"
    read -p "限制CPU核心数 (如 1): " cpu_l < /dev/tty
    read -p "限制内存 (如 512MB): " mem_l < /dev/tty
    [[ -n "$cpu_l" ]] && lxc config set "$cname" limits.cpu "$cpu_l"
    [[ -n "$mem_l" ]] && lxc config set "$cname" limits.memory "$mem_l"
    echo -e "${GREEN}✅ 容器 $cname 已就绪。${NC}"
}

# --- 3. 主菜单逻辑 (修复无限循环) ---
main_menu() {
    init_shortcut
    
    while true; do
        echo -e "\n${BLUE}====================================${NC}"
        echo -e "${GREEN}      sockc LXC 极客面板 v4.1       ${NC}"
        echo -e "${BLUE}====================================${NC}"
        echo "1. 创建新容器 (自定义/限额)"
        echo "2. 快照管理 (备份/回滚)"
        echo "3. 容器列表 & 状态查看"
        echo "4. 销毁指定容器"
        echo "5. 修改容器资源限额"
        echo -e "${YELLOW}6. 卸载环境${NC}"
        echo "0. 退出脚本"
        echo -e "${BLUE}------------------------------------${NC}"
        
        if [[ "$SHORTCUT_ADDED" == "1" ]]; then
            echo -e "${YELLOW}提示: 请运行 'source ~/.bashrc' 激活 lxc-mgr 指令${NC}"
            unset SHORTCUT_ADDED
        fi

        read -p "请选择操作 [0-6]: " opt < /dev/tty
        
        case $opt in
            1) create_container ;;
            2) 
                list_containers && {
                    read -p "选择容器编号: " idx < /dev/tty
                    target="${containers[$idx]}"
                    echo "1.拍快照 2.回滚"
                    read -p "选择: " s_opt < /dev/tty
                    [[ "$s_opt" == "1" ]] && { read -p "名: " sn < /dev/tty; lxc snapshot "$target" "$sn"; }
                    [[ "$s_opt" == "2" ]] && { read -p "回滚到名: " rn < /dev/tty; lxc restore "$target" "$rn"; }
                }
                ;;
            3) lxc list ;;
            4) 
                list_containers && {
                    read -p "输入编号删除: " d_idx < /dev/tty
                    lxc delete "${containers[$d_idx]}" --force
                }
                ;;
            5)
                list_containers && {
                    read -p "编号: " idx < /dev/tty
                    read -p "新内存(如 1GB): " m < /dev/tty
                    lxc config set "${containers[$idx]}" limits.memory "$m"
                }
                ;;
            6) 
                read -p "确定卸载? (y/n): " confirm < /dev/tty
                if [[ "$confirm" == "y" ]]; then
                    lxc delete $(lxc list -c n --format csv) --force 2>/dev/null || true
                    sed -i '/alias lxc-mgr=/d' ~/.bashrc
                    sudo apt purge -y lxd lxd-client && sudo apt autoremove -y
                    exit 0
                fi
                ;;
            0) exit 0 ;;
            *) echo -e "${RED}输入错误，请重新选择${NC}" ;;
        esac
    done
}

# 运行前检查权限
[[ $EUID -ne 0 ]] && echo "请用 root 权限运行" && exit 1
main_menu
