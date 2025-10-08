#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
DISK="/dev/nvme0n1"
POOL_NAME="rpool"
HOSTNAME="nixos"
SWAP_SIZE="32G"  # Увеличено для 32GB RAM (можно вернуть на 16G если не нужна гибернация)

echo -e "${GREEN}=== ZFS on Root Installation Script (32GB RAM Optimized) ===${NC}"
echo -e "${YELLOW}WARNING: This script will completely ERASE $DISK!${NC}"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# Check disk exists
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: $DISK not found!${NC}"
    exit 1
fi

# Cleanup previous installations
echo -e "${BLUE}[1/13] Cleaning up previous installations...${NC}"
# Kill any processes using /mnt
fuser -km /mnt 2>/dev/null || true
sleep 2
# Cleanup swap if exists
swapoff -a 2>/dev/null || true
swapoff /dev/zvol/$POOL_NAME/swap 2>/dev/null || true
# Unmount filesystems
zfs unmount -a 2>/dev/null || true
umount -R /mnt 2>/dev/null && echo "  - Filesystems unmounted" || echo "  - No filesystems to unmount"
# Export pool with force
zpool export -f $POOL_NAME 2>/dev/null && echo "  - Pool exported" || echo "  - No pool to export"
# Clear any stuck zvol devices
rm -f /dev/zvol/$POOL_NAME/* 2>/dev/null || true
sleep 3

# Load ZFS module with parameters
echo -e "${BLUE}[2/13] Loading ZFS kernel module with optimized parameters...${NC}"
if lsmod | grep -q zfs; then
    echo "  - ZFS module already loaded, setting parameters..."
else
    modprobe zfs
    echo "  - ZFS module loaded"
fi

# Set ZFS module parameters to prevent deadlocks
echo 32 > /sys/module/zfs/parameters/zvol_threads 2>/dev/null || true
echo 8 > /sys/module/zfs/parameters/zvol_request_sync 2>/dev/null || true
echo "  - Set zvol_threads=32, zvol_request_sync=8"

# Partition disk
echo -e "${BLUE}[3/13] Partitioning disk...${NC}"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 3

sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:BF00 -c 2:"ZFS" "$DISK"
partprobe "$DISK"
sleep 3
echo "  - Partitions created: ${DISK}p1 (EFI), ${DISK}p2 (ZFS)"

# Wait for devices
echo "  - Waiting for devices to settle..."
udevadm settle --timeout=30
sleep 2

# Format EFI
echo -e "${BLUE}[4/13] Formatting EFI partition...${NC}"
mkfs.vfat -F32 -n EFI "${DISK}p1"
echo "  - EFI partition formatted"

# Create ZFS pool with encryption
echo -e "${BLUE}[5/13] Creating encrypted ZFS pool...${NC}"
echo -e "${YELLOW}Enter encryption password for ZFS:${NC}"
zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O relatime=on \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O compression=zstd \
    -O encryption=aes-256-gcm \
    -O keylocation=prompt \
    -O keyformat=passphrase \
    -O mountpoint=none \
    -R /mnt \
    "$POOL_NAME" "${DISK}p2"

echo "  - ZFS pool '$POOL_NAME' created with native encryption"

# Create datasets with proper mountpoints
echo -e "${BLUE}[6/13] Creating ZFS datasets...${NC}"

# Root dataset
zfs create -o mountpoint=none "$POOL_NAME/root"
echo "  - Created $POOL_NAME/root"

# Root filesystem - монтируется в /
zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/root/nixos"
echo "  - Created $POOL_NAME/root/nixos (mountpoint=/)"

# Home - монтируется в /home
zfs create -o mountpoint=/home "$POOL_NAME/home"
echo "  - Created $POOL_NAME/home (mountpoint=/home)"

# Nix store - монтируется в /nix, lz4 для бинарников
zfs create -o mountpoint=/nix -o compression=lz4 "$POOL_NAME/nix"
echo "  - Created $POOL_NAME/nix (mountpoint=/nix, lz4 compression)"

# Var - монтируется в /var, оптимизирован для логов
zfs create -o mountpoint=/var -o recordsize=16K -o logbias=throughput "$POOL_NAME/var"
echo "  - Created $POOL_NAME/var (mountpoint=/var)"

# Var log - монтируется в /var/log
zfs create -o mountpoint=/var/log -o recordsize=16K "$POOL_NAME/var/log"
echo "  - Created $POOL_NAME/var/log (mountpoint=/var/log)"

# Wait for ZFS to settle before mounting
echo -e "${BLUE}[7/13] Waiting for ZFS to settle...${NC}"
sleep 5
sync
zpool sync "$POOL_NAME"
udevadm settle --timeout=30
echo "  - ZFS datasets ready"

# Mount filesystems FIRST (before creating zvol)
echo -e "${BLUE}[8/13] Mounting filesystems...${NC}"

# Export pool to clear any mount issues
zpool export "$POOL_NAME"
echo "  - Pool exported for clean reimport"
sleep 3

# Import pool with altroot, but don't mount automatically
zpool import -d /dev/disk/by-id -N -R /mnt "$POOL_NAME"
echo "  - Pool imported with altroot=/mnt (no auto-mount)"

# Load encryption keys
echo "  - Loading encryption keys..."
zfs load-key -a
sleep 2

# Mount datasets one by one with proper order
echo "  - Mounting root dataset..."
zfs mount "$POOL_NAME/root/nixos"
sleep 2
sync

echo "  - Mounting home..."
zfs mount "$POOL_NAME/home"
sleep 1

echo "  - Mounting nix..."
zfs mount "$POOL_NAME/nix"
sleep 1

echo "  - Mounting var..."
zfs mount "$POOL_NAME/var"
sleep 1

echo "  - Mounting var/log..."
zfs mount "$POOL_NAME/var/log"
sleep 1

# Create boot directory and mount EFI
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot
echo "  - Mounted ${DISK}p1 -> /mnt/boot"

echo -e "${BLUE}[9/13] All filesystems mounted successfully!${NC}"

# NOW create swap zvol AFTER all filesystems are mounted
echo -e "${BLUE}[10/13] Creating swap zvol ($SWAP_SIZE) - ПОСЛЕ монтирования ФС...${NC}"
zfs create -V "$SWAP_SIZE" -b $(getconf PAGESIZE) \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    -o org.freebsd:swap=on \
    "$POOL_NAME/swap"

echo "  - Created $POOL_NAME/swap zvol"

# Wait for zvol device to appear
echo "  - Waiting for swap zvol device..."
for i in {1..30}; do
    if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
        echo "  - Swap zvol device ready"
        break
    fi
    sleep 1
done

# Ensure device is ready
udevadm settle --timeout=30
sleep 2

# Format swap but DON'T activate it yet
echo -e "${BLUE}[11/13] Formatting swap (not activating)...${NC}"
if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
    mkswap -f /dev/zvol/$POOL_NAME/swap
    echo "  - Swap formatted (will be activated on boot)"
    # НЕ ВКЛЮЧАЕМ swap сейчас, чтобы избежать проблем
    # swapon будет выполнен системой при загрузке
else
    echo -e "${YELLOW}  - Warning: Swap zvol device not found${NC}"
fi

echo -e "\n${GREEN}Filesystem layout:${NC}"
df -h /mnt /mnt/home /mnt/nix /mnt/var /mnt/boot 2>/dev/null | grep -E '(Filesystem|/mnt)' || true

echo -e "\n${GREEN}ZFS mountpoints:${NC}"
zfs list -o name,mountpoint,mounted | grep -v "@"

# Create initial snapshot
echo -e "${BLUE}[12/13] Creating initial snapshot...${NC}"
zfs snapshot -r "$POOL_NAME@initial"
echo "  - Created snapshot: $POOL_NAME@initial"

# Generate NixOS config
echo -e "${BLUE}[13/13] Generating NixOS configuration...${NC}"
nixos-generate-config --root /mnt
echo "  - Hardware configuration generated"

# Get hostId
HOST_ID=$(head -c 8 /etc/machine-id)

# Create optimized configuration
cat > /mnt/etc/nixos/configuration.nix << 'NIXEOF'
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 10;
  
  # ZFS support - правильная конфигурация для зашифрованного root
  boot.supportedFilesystems = [ "zfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];
  
  # Использовать /dev/disk/by-id для стабильности
  boot.zfs.devNodes = "/dev/disk/by-id";
  
  # НЕ форсировать импорт
  boot.zfs.forceImportRoot = false;
  
  # КРИТИЧНО: Запросить пароль для root dataset
  boot.zfs.requestEncryptionCredentials = [ "rpool/root/nixos" ];
  
  # Host ID (будет заменён скриптом)
  networking.hostId = "HOSTID_PLACEHOLDER";
  
  # ZFS kernel params - ОПТИМИЗИРОВАНО ДЛЯ 32GB RAM
  boot.kernelParams = [ 
    "zfs.zfs_arc_max=17179869184"    # 16GB ARC max (50% от 32GB RAM)
    "zfs.zfs_arc_min=4294967296"     # 4GB ARC min
    "zfs.zvol_threads=32"             # Больше потоков для zvol
    "zfs.zvol_request_sync=8"         # Уменьшить синхронные запросы
    "zfs.zfs_taskq_batch_pct=75"      # Улучшенная обработка очередей
    "zfs.zvol_inhibit_dev=0"          # Разрешить создание устройств zvol
    "zfs.zfs_vdev_async_write_min_active=8"
    "zfs.zfs_vdev_async_write_max_active=32"
    "zfs.l2arc_noprefetch=0"          # Включить prefetch для L2ARC (если добавите)
    "zfs.l2arc_write_max=134217728"   # 128MB/s запись в L2ARC (если добавите)
  ];
  
  # Kernel modules to load early
  boot.initrd.kernelModules = [ "zfs" ];
  
  # Специальные sysctl для 32GB RAM и предотвращения deadlock со swap на zvol
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;                 # Меньше использовать swap
    "vm.min_free_kbytes" = 262144;        # 256MB минимум свободной памяти (больше для 32GB)
    "vm.dirty_background_ratio" = 5;      # Раньше начинать запись
    "vm.dirty_ratio" = 10;                 # Меньше грязных страниц
    "vm.vfs_cache_pressure" = 50;         # Баланс между page cache и slab cache
  };
  
  # ZFS services
  services.zfs.autoScrub = {
    enable = true;
    interval = "weekly";
  };
  
  services.zfs.trim = {
    enable = true;
    interval = "weekly";
  };
  
  # Автоснапшоты (исключаем swap)
  services.zfs.autoSnapshot = {
    enable = true;
    frequent = 4;
    hourly = 24;
    daily = 7;
    weekly = 4;
    monthly = 12;
  };
  
  # Swap на zvol с правильными настройками
  swapDevices = [{
    device = "/dev/zvol/rpool/swap";
    priority = 100;
    randomEncryption.enable = false;  # Уже зашифровано через ZFS
  }];
  
  # Hostname
  networking.hostName = "HOSTNAME_PLACEHOLDER";
  
  # Timezone
  time.timeZone = "Asia/Almaty";
  
  # Localization
  i18n.defaultLocale = "en_US.UTF-8";
  
  # Console
  console = {
    keyMap = "us";
  };
  
  # Users
  users.users.luminous = {
    isNormalUser = true;
    initialPassword = "2477";
    extraGroups = [ "wheel" "networkmanager" "video" ];
  };
  
  # System packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
    htop
    zfs
  ];
  
  # NetworkManager
  networking.networkmanager.enable = true;
  
  # SSH
  services.openssh.enable = true;
  
  # NixOS version
  system.stateVersion = "24.05";
}
NIXEOF

# Replace placeholders
sed -i "s/HOSTID_PLACEHOLDER/$HOST_ID/" /mnt/etc/nixos/configuration.nix
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/" /mnt/etc/nixos/configuration.nix

echo "  - Configuration created with hostId: $HOST_ID"

# Set cachefile for pool
echo -e "${BLUE}Setting up ZFS cache...${NC}"
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

# Copy cache to new system
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache 2>/dev/null || echo "  - No zpool.cache to copy (will be created on first boot)"

echo -e "\n${GREEN}=== Installation preparation complete! ===${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. (Optional) Edit /mnt/etc/nixos/configuration.nix"
echo "2. Run: nixos-install"
echo "3. Set root password when prompted"
echo "4. Reboot: reboot"
echo ""
echo -e "${RED}IMPORTANT:${NC}"
echo "  • You will be prompted for ZFS encryption password at boot!"
echo "  • Swap is on zvol but will only be activated AFTER boot to prevent deadlocks"
echo ""
echo -e "${GREEN}Optimizations for 32GB RAM:${NC}"
echo "  ✓ ARC: 16GB max (50% RAM) / 4GB min"
echo "  ✓ Swap: 32GB zvol (поддержка гибернации)"
echo "  ✓ vm.min_free_kbytes: 256MB (больше буфер)"
echo "  ✓ L2ARC ready параметры (если добавите SSD позже)"
echo ""
echo -e "${GREEN}Key improvements in this version:${NC}"
echo "  ✓ Swap zvol created AFTER all filesystems are mounted"
echo "  ✓ Swap formatted but NOT activated during install (prevents deadlock)"
echo "  ✓ Optimized for 32GB RAM with larger ARC"
echo "  ✓ Proper mounting order with -N flag (no auto-mount)"
echo "  ✓ Added org.freebsd:swap=on property to swap zvol"
echo "  ✓ Reduced vm.swappiness to minimize swap usage"
echo ""
echo -e "${GREEN}ZFS dataset configuration:${NC}"
echo "  ✓ rpool/root/nixos -> / (root filesystem)"
echo "  ✓ rpool/home -> /home"
echo "  ✓ rpool/nix -> /nix (lz4 compression)"
echo "  ✓ rpool/var -> /var"
echo "  ✓ rpool/var/log -> /var/log"
echo "  ✓ rpool/swap -> zvol for swap (32GB, zle compression)"
echo ""
echo -e "${GREEN}После установки можете добавить:${NC}"
echo "  • HDD для бэкапов: zpool create backup /dev/sdb"
echo "  • SSD для быстрых задач: zpool create fast /dev/sda"
echo "  • SSD как L2ARC кэш: zpool add rpool cache /dev/sda"
echo ""
echo -e "${BLUE}Pool status:${NC}"
zpool status $POOL_NAME || true
echo ""
echo -e "${BLUE}Zvol devices:${NC}"
ls -la /dev/zvol/$POOL_NAME/ 2>/dev/null || echo "No zvol devices visible yet"
echo ""
echo -e "${BLUE}Dataset properties:${NC}"
zfs get mountpoint,mounted,compression -t filesystem,volume "$POOL_NAME" | grep -v "@" || true