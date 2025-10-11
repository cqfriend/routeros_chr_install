#!/bin/bash

set -e  # 遇到错误立即退出

# ========== 默认值 ==========
DEFAULT_ROS_VERSION="7.20.1"
DEFAULT_ADMIN_PASSWORD="admin@2023"
DEFAULT_WINBOX_PORT="24722"

# ========== 通过命令行参数接收，否则使用默认值 ==========
ROS_VERSION="$DEFAULT_ROS_VERSION"
ADMIN_PASSWORD="$DEFAULT_ADMIN_PASSWORD"
WINBOX_PORT="$DEFAULT_WINBOX_PORT"

# 简单用法提示
usage() {
    echo "Usage: $0 [-v ROS_VERSION] [-pass ADMIN_PASSWORD] [-port WINBOX_PORT]"
    echo "  -v, --ros-version   RouterOS version (default: $DEFAULT_ROS_VERSION)"
    echo "  -pass, --admin-password  Admin password (default: $DEFAULT_ADMIN_PASSWORD)"
    echo "  -port, --winbox-port   WinBox port (default: $DEFAULT_WINBOX_PORT)"
    exit 1
}

# 使用 getopts 处理短选项 （-v, -pass, -port）
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--ros-version)
            ROS_VERSION="$2"
            shift 2
            ;;
        -pass|--admin-password)
            ADMIN_PASSWORD="$2"
            shift 2
            ;;
        -port|--winbox-port)
            WINBOX_PORT="$2"
            shift 2
            ;;
        *)
            echo "❌ Unknown option: $1"
            usage
            ;;
    esac
done

echo "==========================================="
echo "  MikroTik CHR Image Builder (v7.x)"
echo "  RouterOS Version: $ROS_VERSION"
echo "  Admin Password: $ADMIN_PASSWORD"
echo "  WinBox Port: $WINBOX_PORT"
echo "==========================================="

# === 按任意键继续 ===
read -n 1 -s -r -p "⏸ 按任意键继续执行 ..."
echo -e "\n" 


if [ -d "/sys/firmware/efi" ]; then
    BOOT_MODE="uefi"
    CHR_ZIP="chr-${ROS_VERSION}.img.zip"
    echo "✔ Detected UEFI boot mode"
else
    BOOT_MODE="bios"
    CHR_ZIP="chr-${ROS_VERSION}-legacy-bios.img.zip"
    echo "✔ Detected Legacy BIOS boot mode"
fi

DISK_DEVICE=$(fdisk -l 2>/dev/null | grep "^Disk /dev" | grep -v "/dev/loop" | head -n1 | cut -d' ' -f2 | tr -d ':')
if [ -z "$DISK_DEVICE" ]; then
    echo "❌ Error: No target disk found (excluding loop devices)."
    exit 1
fi
echo "➡ Target disk: $DISK_DEVICE"

echo "📥 Downloading CHR image: $CHR_ZIP"
wget -N "https://github.com/elseif/MikroTikPatch/releases/download/${ROS_VERSION}/${CHR_ZIP}" && gunzip -c "$CHR_ZIP" > chr.img

echo "📥 Downloading container package..."
wget -N "https://download.mikrotik.com/routeros/${ROS_VERSION}/container-${ROS_VERSION}.npk"

echo "🔍 Checking partitions..."
START_SECTOR=$(fdisk -l chr.img 2>/dev/null | awk '/^chr\.img2/ {print $2; exit}')
if [ -z "$START_SECTOR" ]; then
    echo "❌ Error: Cannot find chr.img2 partition in chr.img"
    exit 1
fi
OFFSET=$((START_SECTOR * 512))
echo "➡ Mounting rw partition (offset: $OFFSET bytes)"

mkdir -p /mnt
mount -o loop,offset=$OFFSET chr.img /mnt

echo "📝 Writing autorun.scr..."
cat > /mnt/rw/autorun.scr <<EOF
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set ssh disabled=yes
/ip service set api disabled=yes
/ip service set winbox port=$WINBOX_PORT
/ip service set api-ssl disabled=yes
/user set admin password=$ADMIN_PASSWORD
/ip dhcp-client add interface=ether1
EOF

echo "📝 Writing rosmode.msg..."
echo -e -n "\x4d\x32\x01\x00\x00\x29\x0b\x4d\x32\x1c\x00\x00\x01\x0a\x00\x00\x09\x00" > /mnt/rw/rosmode.msg

echo "📦 Installing container package..."
mkdir -p /mnt/var/pdb/container
mv -f "container-${ROS_VERSION}.npk" /mnt/var/pdb/container/image

umount /mnt
echo "⏏️ Unmounted image."

echo "💾 Writing image to $DISK_DEVICE..."
dd if=chr.img of="$DISK_DEVICE" bs=4M oflag=sync status=progress

echo "✅ Image written successfully!"
sync
sleep 1
echo "🔄 Rebooting in 3 seconds..."
sleep 3
echo 1 > /proc/sys/kernel/sysrq
echo b > /proc/sysrq-trigger
