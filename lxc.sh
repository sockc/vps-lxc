#!/bin/bash

# ====================================================
# 项目: sockc LXC 全功能自动化管理工具 (v4.0)
# 功能: 快捷入口、一键卸载、多容器、快照回滚、资源限额
# 架构: 支持 ARM64 / x86_64
# ====================================================

export GREEN='\033[0;32m'
export RED='\033[0;31m'
export YELLOW='\033[0;33m'
export BLUE='\033[0;34m'
export NC='\033[0m'

# 获取当前脚本的绝对路径，用于设置快捷入口
SCRIPT_PATH=$(readlink -f "$0")

# --- 1. 环境初始化与快捷入口设置 ---
init_shortcut() {
    if ! grep -q "alias lxc-mgr=" ~/.bashrc; then
        echo "alias lxc-mgr='bash $SCRIPT_PATH'" >> ~/.bashrc
        echo -e "${GREEN}✅ 快捷入口已建立！以后输入 lxc-mgr 即可进入此菜单。${NC}"
        # 提醒用户 source
        export SHORTCUT_ADDED=1
    fi
}

# --- 2. 一键卸载功能 ---
uninstall_all() {
    echo -e "${RED}⚠️  警告：这将删除所有容器、快照并卸载 LXD 环境！${NC}"
    read -p "确定要执行彻底卸载吗? (y/n): " confirm
    if [[ "$confirm" == "y" ]]; then
        echo -e "${BLUE}正在清理容器...${NC}"
        lxc delete $(lxc list -c n --format csv) --force 2>/dev/null || true
        
        echo -e "${BLUE}正在移除快捷指令...${NC}"
        sed -i '/alias lxc-mgr=/d' ~/.bashrc
        sed -i '/mk-test()/,/}/d' ~/.bashrc
        
        echo -e "${BLUE}正在卸载 LXD 软件包...${NC}"
        sudo apt purge -y lxd lxd-client && sudo apt autoremove -y
        
        echo -e "${GREEN}✅ 卸载完成！系统已恢复纯净。${NC}"
        exit 0
    fi
}

# --- 3. 基础列表函数 ---
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

# --- 4. 创建与限制资源 ---
create_container() {
    read -p "请输入容器名称: " cname
    cname=${cname:-test-$(date +%s)}
    
    echo -e "选择系统: 1.Ubuntu 24.04  2.Debian 12  3.Alpine"
    read -p "请选择: " img_num
    case $img_num in
        2) img="images:debian/12" ;;
        3) img="images:alpine/latest" ;;
        *) img="images:ubuntu/24.04" ;;
    esac

    lxc launch "$img" "$cname"

    echo -e "${BLUE}配置资源限制 (直接回车跳过):${NC}"
    read -p "限制CPU核心数 (如 1): " cpu_limit
    read -p "限制内存大小 (如 1GB): " mem_limit
    [[ -n "$cpu_limit" ]] && lxc config set "$cname" limits.cpu "$cpu_limit"
    [[ -n "$mem_limit" ]] && lxc config set "$cname" limits.memory "$mem_limit"

    echo -e "${GREEN}✅ 容器 $cname 已创建。${NC}"
}

# --- 5. 快照管理 ---
manage_snapshots() {
    list_containers || return
    read -p "选择容器编号: " idx
    local target="${containers[$idx]}"
    echo -e "1.拍摄快照  2.回滚快照  3.查看/删除快照"
    read -p "请选择: " s_opt
    case $s_opt in
        1) read -p "快照名: " sn; lxc snapshot "$target" "$sn" ;;
        2) read -p "回滚到哪个快照? " rn; lxc restore "$target" "$rn" ;;
        3) lxc info "$target" | sed -n '/Snapshots:/,$p' ;;
    esac
}

# --- 主菜单 ---
main_menu() {
    init_shortcut
    echo -e "\n${BLUE}====================================${NC}"
    echo -e "${GREEN}      sockc LXC 极客面板 v4.0       ${NC}"
    echo -e "${BLUE}====================================${NC}"
    echo "1. 创建新容器 (自定义/限额)"
    echo "2. 快照管理 (一键备份/回滚)"
    echo "3. 容器列表 & 状态查看"
    echo "4. 管理 IPv6 独立开关"
    echo "5. 销毁指定容器"
    echo "6. 修改已有容器资源限额"
    echo -e "${YELLOW}7. 卸载本脚本及 LXD 环境${NC}"
    echo "0. 退出"
    echo -e "${BLUE}------------------------------------${NC}"
    [[ "$SHORTCUT_ADDED" == "1" ]] && echo -e "${YELLOW}提示: 请运行 'source ~/.bashrc' 激活 lxc-mgr 指令${NC}"
    read -p "请选择操作: " opt
    case $opt in
        1) create_container ;;
        2) manage_snapshots ;;
        3) lxc list ;;
        4) # 调用之前的IPv6逻辑... 
           ;;
        5) list_containers && read -p "输入编号删除: " d_idx && lxc delete "${containers[$d_idx]}" --force ;;
        6) # 调整资源逻辑...
           ;;
        7) uninstall_all ;;
        0) exit 0 ;;
    esac
    main_menu
}

main_menu
