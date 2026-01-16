#!/bin/bash

# ==========================================================
# Smart Image Master V8.0 - 系统备份工具 (全能旗舰版)
# 功能：DD / Tar / Btrfs快照 / Rsync同步 / 进度显示
# ==========================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 全局变量
DB_STOPPED=0
MOUNT_POINT="/mnt/data"       # 备份存放点
TEMP_SRC_MOUNT="/mnt/src_tmp" # 临时挂载点
IS_TEMP_MOUNT=0               # 标记是否执行了临时挂载
SNAPSHOT_NAME="backup_snap_tmp" # Btrfs临时快照名

# 捕获 Ctrl+C
trap 'echo -e "\n${RED}[WARN] 检测到中断，正在清理...${NC}"; cleanup; exit 1' SIGINT

# =========================
# 基础工具
# =========================
check_dependencies() {
    local missing=0
    for cmd in zstd pv dd lsblk tar rsync btrfs; do
        if ! command -v $cmd &> /dev/null; then missing=1; fi
    done
    if [ $missing -eq 1 ]; then
        echo -e "${CYAN}>>> 正在安装依赖...${NC}"
        if command -v opkg &> /dev/null; then opkg update && opkg install zstd pv coreutils-dd tar rsync btrfs-progs
        elif command -v apt-get &> /dev/null; then apt-get update && apt-get install -y zstd pv tar rsync btrfs-progs; fi
    fi
}

stop_services() {
    if command -v systemctl &> /dev/null && systemctl is-active --quiet postgresql; then
        echo -e "${YELLOW}[INFO] 暂停数据库 (PostgreSQL)...${NC}"
        systemctl stop postgresql && DB_STOPPED=1
    fi
}

start_services() {
    if [ $DB_STOPPED -eq 1 ]; then
        echo -e "${GREEN}[INFO] 恢复数据库 (PostgreSQL)...${NC}"
        systemctl start postgresql
        DB_STOPPED=0
    fi
}

cleanup() {
    start_services
    
    # 清理 Btrfs 临时快照 (如果有)
    # 注意：需要找到挂载点才能删除快照
    if [ -n "$SRC_MOUNT_FOR_SNAP" ] && [ -d "$SRC_MOUNT_FOR_SNAP/$SNAPSHOT_NAME" ]; then
        echo -e "${CYAN}[INFO] 清理临时 Btrfs 快照...${NC}"
        btrfs subvolume delete "$SRC_MOUNT_FOR_SNAP/$SNAPSHOT_NAME" >/dev/null 2>&1
    fi

    # 卸载临时挂载
    if [ $IS_TEMP_MOUNT -eq 1 ]; then
        if mount | grep -q "$TEMP_SRC_MOUNT"; then
            echo -e "${CYAN}[INFO] 正在卸载临时源挂载点...${NC}"
            umount "$TEMP_SRC_MOUNT"
        fi
        rmdir "$TEMP_SRC_MOUNT" 2>/dev/null
        IS_TEMP_MOUNT=0
    fi
}

# =========================
# 备份核心逻辑
# =========================
do_backup() {
    while true; do
        clear
        echo -e "${BLUE}=== 系统备份向导 ===${NC}"
        echo "0) < 返回主菜单"
        echo ""
        
        # --- [Step 1] 选择源 ---
        echo -e "${YELLOW}[Step 1] 请选择源设备 (硬盘或分区):${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v "loop"
        echo ""
        read -p "源设备名称 (例如 sda1，输入 0 返回): " SRC_NAME
        [[ "$SRC_NAME" == "0" ]] && return
        [[ -z "$SRC_NAME" ]] && continue
        
        if [[ "$SRC_NAME" != /dev/* ]]; then SRC_DEV="/dev/$SRC_NAME"; else SRC_DEV="$SRC_NAME"; fi
        if [ ! -b "$SRC_DEV" ]; then echo -e "${RED}[ERROR] 设备不存在${NC}"; sleep 1; continue; fi
        
        # 获取源文件系统类型
        SRC_FS=$(lsblk -no FSTYPE "$SRC_DEV")

        # --- [Step 2] 选择目标 ---
        echo -e "\n${YELLOW}[Step 2] 请选择备份存放的目标分区 (数据盘):${NC}"
        lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -v "loop" | grep -v "$SRC_NAME"
        echo ""
        read -p "目标分区名称 (例如 sdb2): " DEST_PART
        [[ "$DEST_PART" == "0" ]] && return
        [[ -z "$DEST_PART" ]] && continue
        
        if [[ "$DEST_PART" != /dev/* ]]; then DEST_DEV="/dev/$DEST_PART"; else DEST_DEV="$DEST_PART"; fi
        if [ ! -b "$DEST_DEV" ]; then echo -e "${RED}[ERROR] 分区不存在${NC}"; sleep 1; continue; fi

        # 自动挂载目标
        CURRENT_MOUNT=$(lsblk -no MOUNTPOINT "$DEST_DEV")
        if [ -n "$CURRENT_MOUNT" ]; then
            DEST_PATH="$CURRENT_MOUNT/backup"
        else
            mkdir -p "$MOUNT_POINT"
            mount "$DEST_DEV" "$MOUNT_POINT" || { echo -e "${RED}[ERROR] 挂载失败${NC}"; sleep 2; continue; }
            DEST_PATH="$MOUNT_POINT/backup"
        fi
        mkdir -p "$DEST_PATH"

        # --- [Step 3] 选择备份模式 ---
        echo -e "\n${YELLOW}[Step 3] 请选择备份模式:${NC}"
        echo "1) [DD ] 物理镜像 - 适合全盘/系统盘，含引导，还原最稳"
        echo "2) [Tar] 文件归档 - 通用文件备份，体积小"
        echo "3) [Btrfs] 快照流 - (仅限 Btrfs) 极速、支持增量、需源为 Btrfs"
        echo "4) [Rsync] 目录同步 - 镜像到文件夹，可直接查看文件"
        read -p "请选择 [默认 1]: " MODE_CHOICE
        
        # 校验 Btrfs 模式
        if [ "$MODE_CHOICE" == "3" ] && [ "$SRC_FS" != "btrfs" ]; then
            echo -e "${RED}[ERROR] 源设备不是 Btrfs 文件系统，无法使用此模式！${NC}"
            read -p "按回车重新选择..."
            continue
        fi

        # --- [Step 4] 选择压缩算法 (Rsync跳过此步) ---
        if [ "$MODE_CHOICE" != "4" ]; then
            echo -e "\n${YELLOW}[Step 4] 请选择压缩方式:${NC}"
            echo "1) [推荐] Zstd (速度快，压缩率高)"
            echo "2) [兼容] Gzip (通用性好，较慢)"
            echo "3) [原生] 不压缩 (速度最快，体积大)"
            read -p "请选择 [默认 1]: " COMP_CHOICE
        else
            COMP_CHOICE="3" # Rsync 默认不打包压缩
        fi

        # 构建文件名和命令
        TIMESTAMP=$(date +%Y%m%d_%H%M)
        case "$COMP_CHOICE" in
            2) C_EXT="gz";  C_CMD="gzip -c";;
            3) C_EXT="raw"; C_CMD="cat";;
            *) C_EXT="zst"; C_CMD="zstd -T0 -3";;
        esac

        case "$MODE_CHOICE" in
            2) B_TYPE="tar";   FILE_NAME="${DEST_PATH}/backup_${SRC_NAME}_tar_${TIMESTAMP}.tar.${C_EXT}";;
            3) B_TYPE="btrfs"; FILE_NAME="${DEST_PATH}/backup_${SRC_NAME}_btrfs_${TIMESTAMP}.send.${C_EXT}";;
            4) B_TYPE="rsync"; FILE_NAME="${DEST_PATH}/backup_${SRC_NAME}_rsync_${TIMESTAMP}";; # 这是目录名
            *) B_TYPE="dd";    FILE_NAME="${DEST_PATH}/backup_${SRC_NAME}_dd_${TIMESTAMP}.img.${C_EXT}";;
        esac

        # --- 任务确认 ---
        echo -e "\n${GREEN}>>> 任务确认 <<<${NC}"
        echo -e "源设备:   $SRC_DEV ($SRC_FS)"
        echo -e "备份模式: $B_TYPE"
        if [ "$B_TYPE" == "rsync" ]; then
            echo -e "保存目录: $FILE_NAME (文件夹)"
        else
            echo -e "保存文件: $FILE_NAME"
            echo -e "压缩方式: $C_EXT"
        fi
        
        read -p "确认开始? (y/n): " CONFIRM
        [[ "$CONFIRM" != "y" ]] && continue

        stop_services
        echo -e "\n${CYAN}[RUNNING] 正在备份...${NC}"
        START_TIME=$(date +%s)

        # === 准备源挂载点 (Tar/Rsync/Btrfs 需要挂载) ===
        if [ "$B_TYPE" != "dd" ]; then
            mkdir -p "$TEMP_SRC_MOUNT"
            SRC_IS_MOUNTED=$(lsblk -no MOUNTPOINT "$SRC_DEV")
            
            if [ -n "$SRC_IS_MOUNTED" ]; then
                TARGET_DIR="$SRC_IS_MOUNTED"
                echo -e "${GREEN}[SAFE] 源已挂载于 $TARGET_DIR${NC}"
                IS_TEMP_MOUNT=0
            else
                echo -e "${CYAN}[INFO] 临时挂载源 $SRC_DEV ...${NC}"
                mount "$SRC_DEV" "$TEMP_SRC_MOUNT"
                TARGET_DIR="$TEMP_SRC_MOUNT"
                IS_TEMP_MOUNT=1
            fi
        fi

        # === 执行备份 ===
        if [ "$B_TYPE" == "dd" ]; then
            # 1. DD 模式
            dd if="$SRC_DEV" bs=4M status=none | pv -s $(blockdev --getsize64 "$SRC_DEV") | $C_CMD > "$FILE_NAME"
            
        elif [ "$B_TYPE" == "tar" ]; then
            # 2. Tar 模式
            tar --warning=no-file-changed -cpf - \
                --exclude='./proc/*' --exclude='./sys/*' --exclude='./tmp/*' \
                --exclude='./run/*' --exclude='./mnt/*' --exclude='./dev/*' \
                -C "$TARGET_DIR" . | pv | $C_CMD > "$FILE_NAME"
                
        elif [ "$B_TYPE" == "btrfs" ]; then
            # 3. Btrfs 模式
            # 创建只读快照 -> 发送 -> 删除快照
            SRC_MOUNT_FOR_SNAP="$TARGET_DIR" # 记录挂载点用于清理
            echo -e "${CYAN}[INFO] 创建 Btrfs 只读快照...${NC}"
            btrfs subvolume snapshot -r "$TARGET_DIR" "$TARGET_DIR/$SNAPSHOT_NAME"
            
            echo -e "${CYAN}[INFO] 发送数据流...${NC}"
            # btrfs send 的输出通过管道压缩
            btrfs send "$TARGET_DIR/$SNAPSHOT_NAME" | pv | $C_CMD > "$FILE_NAME"
            
            # 清理快照
            btrfs subvolume delete "$TARGET_DIR/$SNAPSHOT_NAME" >/dev/null 2>&1
            
        elif [ "$B_TYPE" == "rsync" ]; then
            # 4. Rsync 模式
            mkdir -p "$FILE_NAME"
            echo -e "${CYAN}[INFO] 开始同步文件...${NC}"
            # -aAX: 归档+ACL+Xattr, --info=progress2: 显示总进度
            rsync -aAX --info=progress2 \
                --exclude='/proc/*' --exclude='/sys/*' --exclude='/tmp/*' \
                --exclude='/run/*' --exclude='/mnt/*' --exclude='/dev/*' \
                "$TARGET_DIR/" "$FILE_NAME/"
        fi

        if [ $? -eq 0 ]; then
            END_TIME=$(date +%s)
            echo -e "\n${GREEN}[SUCCESS] 备份成功!${NC}"
            echo -e "耗时: $((END_TIME - START_TIME)) 秒"
            if [ "$B_TYPE" != "rsync" ]; then
                echo -e "大小: $(du -h "$FILE_NAME" | cut -f1)"
            fi
        else
            echo -e "\n${RED}[ERROR] 备份失败!${NC}"
            [ "$B_TYPE" != "rsync" ] && rm -f "$FILE_NAME"
        fi
        
        cleanup
        if [ -z "$CURRENT_MOUNT" ]; then umount "$MOUNT_POINT"; fi
        read -p "按回车返回..."
        return
    done
}

# =========================
# 还原逻辑 (仅限 DD/Btrfs流)
# =========================
do_restore() {
    while true; do
        clear
        echo -e "${BLUE}=== 系统还原向导 ===${NC}"
        echo "0) < 返回主菜单"
        echo ""
        
        echo -e "${YELLOW}[Step 1] 备份文件在哪里？请输入分区名称 (例如 sdb2):${NC}"
        lsblk -o NAME,SIZE,MOUNTPOINT | grep -v "loop"
        read -p "分区名称: " PART_NAME
        [[ "$PART_NAME" == "0" ]] && return
        if [[ "$PART_NAME" != /dev/* ]]; then PART_DEV="/dev/$PART_NAME"; else PART_DEV="$PART_NAME"; fi
        if [ ! -b "$PART_DEV" ]; then echo "[ERROR] 设备不存在"; sleep 1; continue; fi

        mkdir -p "$MOUNT_POINT"
        mount "$PART_DEV" "$MOUNT_POINT" 2>/dev/null
        SEARCH_PATH="$MOUNT_POINT/backup"
        [ ! -d "$SEARCH_PATH" ] && SEARCH_PATH="$MOUNT_POINT"
        
        echo -e "\n发现备份文件:"
        # 查找 img, tar, send (btrfs流)
        mapfile -t FILES < <(find "$SEARCH_PATH" -maxdepth 2 \( -name "*.img*" -o -name "*.tar*" -o -name "*.send*" \))
        
        if [ ${#FILES[@]} -eq 0 ]; then
            echo -e "${RED}[ERROR] 未找到备份文件!${NC}"; umount "$MOUNT_POINT"; read -p "回车重试..."; continue
        fi

        i=1
        for f in "${FILES[@]}"; do echo "$i) $(basename "$f")"; ((i++)); done
        read -p "请选择文件编号: " F_IDX
        SEL_FILE="${FILES[$((F_IDX-1))]}"
        [ -z "$SEL_FILE" ] && continue
        
        # 警告部分格式无法自动还原
        if [[ "$SEL_FILE" == *.tar* ]] || [[ "$SEL_FILE" == *_rsync_* ]]; then
            echo -e "${RED}[WARN] Tar/Rsync 备份不支持一键全盘还原。${NC}"
            echo -e "请手动挂载目标盘并将文件解压/同步回去。"
            read -p "按回车返回..."; continue
        fi

        echo -e "\n${YELLOW}[Step 2] 还原到哪个设备?${NC}"
        read -p "目标设备 (例如 sda1): " DEST_NAME
        DEST_DEV="/dev/$DEST_NAME"
        
        if mount | grep "on / type" | grep -q "$DEST_NAME"; then
            echo -e "${RED}[FATAL] 不能在 Live 模式还原到系统盘! 请进入 Rescue 模式。${NC}"; read -p "回车返回..."; return
        fi
        
        echo -e "${RED}⚠️  警告：即将把数据覆盖到 $DEST_DEV${NC}"
        read -p "输入 YES 确认: " SURE
        if [[ "$SURE" == "YES" ]]; then
            echo -e "\n${CYAN}[RUNNING] 正在还原...${NC}"
            
            # 解压流
            if [[ "$SEL_FILE" == *.zst ]]; then D_CMD="zstd -d -c"; elif [[ "$SEL_FILE" == *.gz ]]; then D_CMD="gzip -d -c"; else D_CMD="cat"; fi
            
            # 区分 DD 和 Btrfs
            if [[ "$SEL_FILE" == *.send* ]]; then
                # Btrfs 接收
                echo -e "${CYAN}[INFO] 正在挂载目标盘并执行 btrfs receive...${NC}"
                mkdir -p "$TEMP_SRC_MOUNT"
                mount "$DEST_DEV" "$TEMP_SRC_MOUNT"
                $D_CMD "$SEL_FILE" | pv | btrfs receive "$TEMP_SRC_MOUNT"
                umount "$TEMP_SRC_MOUNT"
            else
                # DD 写入
                $D_CMD "$SEL_FILE" | pv | dd of="$DEST_DEV" bs=4M status=none
            fi
            
            echo -e "${GREEN}[SUCCESS] 还原完成。${NC}"
        fi
        
        umount "$MOUNT_POINT"
        read -p "按回车返回..."
        return
    done
}

# =========================
# 主程序
# =========================
check_dependencies
while true; do
    clear
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}    Smart Image Master V8.0 (全能版)    ${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo "1) 备份系统 (DD / Tar / Btrfs / Rsync)"
    echo "2) 还原系统 (支持 .img 和 .send)"
    echo "q) 退出"
    echo ""
    read -p "请输入选项: " CHOICE
    case "$CHOICE" in
        1) do_backup ;;
        2) do_restore ;;
        q|Q) echo "Bye!"; exit 0 ;;
        *) echo "无效选项"; sleep 1 ;;
    esac
done
