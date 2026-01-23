#!/bin/bash
# ==============================================================================
# 脚本名称: Universal Netboot.xyz Installer for GRUB
# 功能描述: 自动下载 Netboot.xyz 内核，配置 GRUB 启动项，支持 x86_64/ARM64
# 作者: Gemini (For User)
# 日期: 2026-01-23
# ==============================================================================

# 设置颜色变量
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 1. 检查 Root 权限
echo -e "${YELLOW}[INFO] 正在检查 Root 权限...${PLAIN}"
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}[ERROR] 此脚本必须以 root 用户运行！${PLAIN}" 
   exit 1
fi

# 2. 检测系统架构 (Architecture Detection)
# 这一步对于你的 Oracle Cloud (可能是 ARM) 和 Google Cloud (x86) 至关重要
ARCH=$(uname -m)
echo -e "${YELLOW}[INFO] 检测到系统架构为: ${ARCH}${PLAIN}"

if [[ "$ARCH" == "x86_64" ]]; then
    NETBOOT_KERNEL="https://boot.netboot.xyz/ipxe/netboot.xyz.lkrn"
    KERNEL_FILENAME="netboot.xyz.lkrn"
    GRUB_ENTRY_TYPE="linux16" # x86通常使用 linux16 加载 lkrn
elif [[ "$ARCH" == "aarch64" ]]; then
    # ARM64 需要不同的 EFI 文件，通常通过 grub 加载 efi 镜像
    # 为了兼容性，我们这里下载通用的 kernel 和 initrd
    NETBOOT_KERNEL="https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi"
    KERNEL_FILENAME="netboot.xyz-arm64.efi"
    # ARM 环境比较复杂，这里采用 chainloader 方式尝试，或者直接下载 kernel/initrd 分离版
    # 为了保证通用性，这里切换为下载 Kernel/Initrd 分离版，这样 GRUB 兼容性最好
    NETBOOT_IMG_KERNEL="https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi" 
    echo -e "${RED}[WARNING] ARM64 (aarch64) 架构支持在 GRUB 中可能存在兼容性问题。${PLAIN}"
    echo -e "${YELLOW}[INFO] 将尝试下载 EFI 文件并配置 Chainloader。${PLAIN}"
else
    echo -e "${RED}[ERROR] 不支持的架构: ${ARCH}${PLAIN}"
    exit 1
fi

# 3. 安装必要的依赖 (自动识别包管理器)
echo -e "${YELLOW}[INFO] 正在安装必要依赖 (wget)...${PLAIN}"
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get install -y wget
elif command -v yum >/dev/null 2>&1; then
    yum install -y wget
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y wget
elif command -v apk >/dev/null 2>&1; then
    apk add wget
else
    echo -e "${RED}[ERROR] 无法识别包管理器，请手动安装 wget。${PLAIN}"
    exit 1
fi

# 4. 下载 Netboot.xyz 引导文件
BOOT_DIR="/boot"
echo -e "${YELLOW}[INFO] 正在下载 Netboot.xyz 镜像到 ${BOOT_DIR}...${PLAIN}"

if [[ "$ARCH" == "x86_64" ]]; then
    # x86_64 下载 .lkrn 文件
    wget --no-check-certificate -O "${BOOT_DIR}/${KERNEL_FILENAME}" "${NETBOOT_KERNEL}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR] 下载失败！请检查网络连接。${PLAIN}"
        exit 1
    fi
elif [[ "$ARCH" == "aarch64" ]]; then
    # ARM64 下载 .efi 文件
    wget --no-check-certificate -O "${BOOT_DIR}/${KERNEL_FILENAME}" "${NETBOOT_KERNEL}"
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[ERROR] 下载失败！${PLAIN}"
        exit 1
    fi
fi

echo -e "${GREEN}[SUCCESS] 下载完成: ${BOOT_DIR}/${KERNEL_FILENAME}${PLAIN}"

# 5. 配置 GRUB 菜单
# 我们不直接修改 /boot/grub/grub.cfg，而是添加一个自定义配置到 /etc/grub.d/40_custom
# 这样运行 update-grub 时会自动生成正确的配置，自动处理 UUID 和 硬盘映射

GRUB_CUSTOM_FILE="/etc/grub.d/40_custom"

echo -e "${YELLOW}[INFO] 正在配置 GRUB 启动项...${PLAIN}"

# 备份原配置文件
if [ -f "$GRUB_CUSTOM_FILE" ]; then
    cp "$GRUB_CUSTOM_FILE" "${GRUB_CUSTOM_FILE}.bak.$(date +%F_%T)"
    echo -e "${YELLOW}[INFO] 已备份原配置文件到 ${GRUB_CUSTOM_FILE}.bak...${PLAIN}"
fi

# 写入引导配置
# 注意：这里利用 GRUB 的 'search' 命令自动查找文件所在的硬盘，无需手动指定 /dev/sda
cat <<EOF > "$GRUB_CUSTOM_FILE"
#!/bin/sh
exec tail -n +3 \$0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.

menuentry 'Netboot.xyz (Reinstall OS)' {
    load_video
    set gfxpayload=keep
    insmod gzio
    insmod part_gpt
    insmod ext2
    insmod xfs
    insmod btrfs
    
    # 自动查找包含 netboot 文件的分区，并设为 root
    search --no-floppy --set=root --file /${KERNEL_FILENAME}
    
    echo 'Loading Netboot.xyz...'
    
    # 根据架构选择启动命令
EOF

if [[ "$ARCH" == "x86_64" ]]; then
    cat <<EOF >> "$GRUB_CUSTOM_FILE"
    linux16 /${KERNEL_FILENAME}
}
EOF
else 
    # ARM64 (通常用于 UEFI 环境)
    cat <<EOF >> "$GRUB_CUSTOM_FILE"
    chainloader /${KERNEL_FILENAME}
}
EOF
fi

# 赋予执行权限
chmod +x "$GRUB_CUSTOM_FILE"
echo -e "${GREEN}[SUCCESS] GRUB 配置文件已更新。${PLAIN}"

# 6. 更新 GRUB 配置
# 这一步会将我们的自定义配置合并到主引导文件中
echo -e "${YELLOW}[INFO] 正在更新 GRUB 主配置...${PLAIN}"

if command -v update-grub >/dev/null 2>&1; then
    update-grub
elif command -v grub2-mkconfig >/dev/null 2>&1; then
    grub2-mkconfig -o /boot/grub2/grub.cfg
elif command -v grub-mkconfig >/dev/null 2>&1; then
    grub-mkconfig -o /boot/grub/grub.cfg
else
    echo -e "${RED}[ERROR] 未找到 update-grub 或 grub-mkconfig 命令。请手动更新 GRUB。${PLAIN}"
    exit 1
fi

echo -e "${GREEN}[SUCCESS] GRUB 更新完成！${PLAIN}"
echo -e "${YELLOW}=============================================================${PLAIN}"
echo -e "${YELLOW}  安装完成！请仔细阅读以下步骤：${PLAIN}"
echo -e "  1. 登录你的云服务商控制台 (Google Cloud / Oracle Cloud / VPS面板)"
echo -e "  2. 打开 **VNC** 或 **VNC Console** 窗口。"
echo -e "  3. 在 SSH 中执行 'reboot' 重启服务器。"
echo -e "  4. 在启动画面出现时，按上下键选择 'Netboot.xyz (Reinstall OS)'。"
echo -e "  5. 进入 Netboot 菜单后，选择 'Linux Network Installs' 开始重装。"
echo -e "${YELLOW}=============================================================${PLAIN}"
