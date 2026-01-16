#!/bin/bash

# ==========================================
# GCP 救援盘自动部署脚本 V2.0 (智能容错版)
# 功能：分区 / 部署镜像 / 配置 Grub / 修复串口
# ==========================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 检查是否以 root 运行
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}❌ 请使用 root 权限运行此脚本 (sudo bash $0)${NC}"
  exit 1
fi

print_header() {
    clear
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}    🚑 GCP Linux 救火队 (Rescue Disk) 部署工具    ${NC}"
    echo -e "${BLUE}==============================================${NC}"
}

# ------------------------------------------
# 选项 1: 磁盘分区
# ------------------------------------------
do_partition() {
    echo -e "${YELLOW}>>> 进入磁盘分区模式...${NC}"
    
    # 列出当前磁盘
    lsblk -d -o NAME,SIZE,MODEL
    echo ""
    read -p "请输入目标磁盘 (例如 sdb 或 /dev/sdb): " INPUT_DISK

    # --- V2.0 新增：智能路径修正 ---
    # 1. 去除两端空格
    INPUT_DISK=$(echo "$INPUT_DISK" | xargs)
    # 2. 去除可能误输入的右括号 )
    INPUT_DISK=$(echo "$INPUT_DISK" | tr -d ')')
    # 3. 如果没有 /dev/ 前缀，自动补全
    if [[ "$INPUT_DISK" != /dev/* ]]; then
        TARGET_DISK="/dev/$INPUT_DISK"
    else
        TARGET_DISK="$INPUT_DISK"
    fi
    # -----------------------------

    # 检查磁盘是否存在
    if [ ! -b "$TARGET_DISK" ]; then
        echo -e "${RED}❌ 错误：磁盘 $TARGET_DISK 不存在！${NC}"
        echo -e "请确认 lsblk 列表中有这个名字。"
        read -p "按回车键重试..."
        return
    fi

    echo -e "${RED}⚠️  警告：该操作将格式化 $TARGET_DISK 的所有数据！${NC}"
    read -p "确定要继续吗？(输入 yes 确认): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo "已取消操作。"
        return
    fi

    read -p "请输入救援分区的大小 (例如 200M, 1G): " PART_SIZE
    if [ -z "$PART_SIZE" ]; then
        PART_SIZE="200M"
        echo "未输入，使用默认值：200M"
    fi

    echo -e "${GREEN}正在对 $TARGET_DISK 进行分区 (Rescue: $PART_SIZE)...${NC}"

    # 自动分区
    sed -e 's/\s*\([\+0-9a-zA-Z]*\).*/\1/' << EOF | fdisk "$TARGET_DISK"
o
n
p
1

+$PART_SIZE
n
p
2


w
EOF

    echo -e "${GREEN}✅ 分区表已更新，正在格式化...${NC}"
    
    # 尝试卸载以防万一
    umount "${TARGET_DISK}1" 2>/dev/null
    umount "${TARGET_DISK}2" 2>/dev/null

    # 格式化
    mkfs.ext4 "${TARGET_DISK}1" -F -L RESCUE
    echo -e "救援分区 (${TARGET_DISK}1) 格式化为 ext4 完成。"
    
    mkfs.btrfs "${TARGET_DISK}2" -f -L DATA
    echo -e "数据分区 (${TARGET_DISK}2) 格式化为 btrfs 完成。"

    echo -e "${GREEN}🎉 磁盘分区操作全部完成！${NC}"
    echo -e "提示：你的救援分区路径是 ${YELLOW}${TARGET_DISK}1${NC}"
    read -p "按回车键返回主菜单..."
}

# ------------------------------------------
# 选项 2: 部署救援镜像
# ------------------------------------------
do_deploy() {
    echo -e "${YELLOW}>>> 进入镜像部署模式...${NC}"
    
    read -p "请输入救援分区的路径 (例如 sdb1 或 /dev/sdb1): " INPUT_PART

    # --- V2.0 新增：智能路径修正 ---
    INPUT_PART=$(echo "$INPUT_PART" | xargs | tr -d ')')
    if [ -z "$INPUT_PART" ]; then
        RESCUE_PART="/dev/sdb1" # 默认值
    elif [[ "$INPUT_PART" != /dev/* ]]; then
        RESCUE_PART="/dev/$INPUT_PART"
    else
        RESCUE_PART="$INPUT_PART"
    fi
    # -----------------------------

    if [ ! -b "$RESCUE_PART" ]; then
        echo -e "${RED}❌ 错误：分区 $RESCUE_PART 不存在！请先执行步骤 1。${NC}"
        read -p "按回车键返回..."
        return
    fi

    MOUNT_POINT="/mnt/rescue_tmp"
    mkdir -p "$MOUNT_POINT"
    
    echo "正在挂载 $RESCUE_PART 到 $MOUNT_POINT ..."
    mount "$RESCUE_PART" "$MOUNT_POINT"
    
    echo "正在下载 mfslinux (0.1.11)..."
    cd "$MOUNT_POINT" || exit
    rm -f rescue.iso
    
    wget -O rescue.iso https://mfsbsd.vx.sk/files/iso/mfslinux/mfslinux-0.1.11-94b1466.iso
    
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✅ 镜像下载成功并已重命名为 rescue.iso${NC}"
    else
        echo -e "${RED}❌ 下载失败，请检查网络！${NC}"
        cd ~
        umount "$MOUNT_POINT"
        return
    fi

    cd ~
    umount "$MOUNT_POINT"
    UUID=$(blkid -s UUID -o value "$RESCUE_PART")
    
    echo -e "${GREEN}🎉 部署完成！${NC}"
    echo -e "检测到救援分区的 UUID 为: ${YELLOW}$UUID${NC}"
    
    export CACHED_UUID="$UUID"
    read -p "按回车键返回主菜单..."
}

# ------------------------------------------
# 选项 3: 配置 Grub 启动菜单
# ------------------------------------------
do_grub() {
    echo -e "${YELLOW}>>> 进入 Grub 配置模式...${NC}"

    DEFAULT_UUID=${CACHED_UUID:-""}
    if [ -n "$DEFAULT_UUID" ]; then
        echo -e "检测到刚才操作的 UUID: ${GREEN}$DEFAULT_UUID${NC}"
        read -p "确认使用此 UUID 吗？(直接回车确认，输入新值覆盖): " INPUT_UUID
        if [ -z "$INPUT_UUID" ]; then
            TARGET_UUID="$DEFAULT_UUID"
        else
            TARGET_UUID="$INPUT_UUID"
        fi
    else
        read -p "请输入救援分区的 UUID (可通过 blkid 查看): " TARGET_UUID
    fi

    if [ -z "$TARGET_UUID" ]; then
        echo -e "${RED}❌ UUID 不能为空！${NC}"
        read -p "按回车键返回..."
        return
    fi

    read -p "请输入启动菜单倒计时秒数 (默认 30): " TIMEOUT_SEC
    if [ -z "$TIMEOUT_SEC" ]; then
        TIMEOUT_SEC="30"
    fi

    echo "正在写入配置..."

    cat <<EOF >> /etc/grub.d/40_custom

menuentry "🚑 Rescue Disk (Setup by Script)" {
    insmod part_msdos
    insmod part_gpt
    insmod ext2
    insmod btrfs
    insmod iso9660
    search --no-floppy --fs-uuid --set=root $TARGET_UUID
    set isofile="/rescue.iso"
    loopback loop (\$root)\$isofile
    linux (loop)/isolinux/vmlinuz iso-scan/filename=\$isofile inst.stage2=hd:LABEL=MFSLINUX memdisk_size=512M
    initrd (loop)/isolinux/initramfs.igz
}
EOF

    cat <<EOF > /etc/default/grub.d/99-force-serial.cfg
# Generated by setup_rescue.sh
GRUB_TERMINAL="console serial"
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
GRUB_TIMEOUT=$TIMEOUT_SEC
GRUB_TIMEOUT_STYLE=menu
EOF

    echo -e "${GREEN}✅ 配置文件写入完成！${NC}"
    echo "正在执行 update-grub 更新引导..."
    update-grub

    echo -e "${GREEN}🎉 Grub 配置已更新！${NC}"
    echo -e "${YELLOW}建议操作：输入 reboot 重启，并在 Cloud Shell 中测试。${NC}"
    read -p "按回车键返回主菜单..."
}

# ------------------------------------------
# 主菜单
# ------------------------------------------
while true; do
    print_header
    echo "请选择操作："
    echo "1) 🛠️  磁盘分区 (自定义大小 + 格式化)"
    echo "2) 📥 部署救援镜像 (下载 mfslinux)"
    echo "3) ⚙️  配置 Grub 菜单 (自定义倒计时 + 串口修复)"
    echo "q) 🚪 退出"
    echo ""
    read -p "请输入选项 [1-3]: " choice

    case $choice in
        1) do_partition ;;
        2) do_deploy ;;
        3) do_grub ;;
        q|Q) echo "再见！👋"; exit 0 ;;
        *) echo -e "${RED}无效选项，请重试。${NC}"; sleep 1 ;;
    esac
done
