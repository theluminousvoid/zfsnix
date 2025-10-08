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
SWAP_SIZE="16G"

echo -e "${GREEN}=== ZFS on Root Installation Script ===${NC}"
echo -e "${YELLOW}WARNING: This script will completely ERASE $DISK!${NC}"
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# Check disk exists
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: $DISK not found!${NC}"
    exit 1
fi

# Cleanup previous installations
echo -e "${BLUE}[1/12] Cleaning up previous installations...${NC}"
swapoff /dev/zvol/$POOL_NAME/swap 2>/dev/null && echo "  - Swap disabled" || echo "  - No swap to disable"
umount -R /mnt 2>/dev/null && echo "  - Filesystems unmounted" || echo "  - No filesystems to unmount"
zpool export $POOL_NAME 2>/dev/null && echo "  - Pool exported" || echo "  - No pool to export"

# Load ZFS module
echo -e "${BLUE}[2/12] Loading ZFS kernel module...${NC}"
if lsmod | grep -q zfs; then
    echo "  - ZFS module already loaded"
else
    modprobe zfs
    echo "  - ZFS module loaded"
fi

# Partition disk
echo -e "${BLUE}[3/12] Partitioning disk...${NC}"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 2

sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:BF00 -c 2:"ZFS" "$DISK"
partprobe "$DISK"
sleep 2
echo "  - Partitions created: ${DISK}p1 (EFI), ${DISK}p2 (ZFS)"

# Format EFI
echo -e "${BLUE}[4/12] Formatting EFI partition...${NC}"
mkfs.vfat -F32 -n EFI "${DISK}p1"
echo "  - EFI partition formatted"

# Create ZFS pool with encryption
echo -e "${BLUE}[5/12] Creating encrypted ZFS pool...${NC}"
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
    "$POOL_NAME" "${DISK}p2"

echo "  - ZFS pool '$POOL_NAME' created with native encryption"

# Create datasets with proper mountpoints
echo -e "${BLUE}[6/12] Creating ZFS datasets...${NC}"

zfs create -o mountpoint=none "$POOL_NAME/root"
echo "  - Created $POOL_NAME/root"

zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/root/nixos"
echo "  - Created $POOL_NAME/root/nixos"

zfs create -o mountpoint=/home "$POOL_NAME/home"
echo "  - Created $POOL_NAME/home"

zfs create -o mountpoint=/nix -o compression=lz4 "$POOL_NAME/nix"
echo "  - Created $POOL_NAME/nix (lz4 compression for binaries)"

zfs create -o mountpoint=/var -o recordsize=16K -o logbias=throughput "$POOL_NAME/var"
echo "  - Created $POOL_NAME/var"

zfs create -o mountpoint=/var/log -o recordsize=16K "$POOL_NAME/var/log"
echo "  - Created $POOL_NAME/var/log"

# Create swap zvol
echo -e "${BLUE}[7/12] Creating swap zvol ($SWAP_SIZE)...${NC}"
zfs create -V "$SWAP_SIZE" -b $(getconf PAGESIZE) \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    "$POOL_NAME/swap"
echo "  - Created $POOL_NAME/swap"

# Wait for zvol device
sleep 3
udevadm settle

# Setup swap
echo -e "${BLUE}[8/12] Setting up swap...${NC}"
if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
    mkswap -f /dev/zvol/$POOL_NAME/swap
    swapon /dev/zvol/$POOL_NAME/swap
    echo "  - Swap enabled"
else
    echo -e "${YELLOW}  - Warning: Swap zvol not found, skipping...${NC}"
fi

# Mount filesystems
echo -e "${BLUE}[9/12] Mounting filesystems...${NC}"

# Export and import with correct altroot
zpool export "$POOL_NAME"
zpool import -d /dev/disk/by-id -R /mnt "$POOL_NAME"

# Mount root
zfs mount "$POOL_NAME/root/nixos"
echo "  - Mounted $POOL_NAME/root/nixos -> /mnt"

# Mount other datasets
zfs mount -a
echo "  - Mounted all ZFS datasets"

# Mount boot
mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot
echo "  - Mounted ${DISK}p1 -> /mnt/boot"

echo -e "\n${GREEN}Filesystem layout:${NC}"
df -h /mnt /mnt/home /mnt/nix /mnt/var /mnt/boot 2>/dev/null | grep -E '(Filesystem|/mnt)' || echo "Filesystems mounted successfully"

# Create initial snapshot
echo -e "${BLUE}[10/12] Creating initial snapshot...${NC}"
zfs snapshot -r "$POOL_NAME@initial"
echo "  - Created snapshot: $POOL_NAME@initial"

# Generate NixOS config
echo -e "${BLUE}[11/12] Generating NixOS configuration...${NC}"
nixos-generate-config --root /mnt
echo "  - Hardware configuration generated"

# Get hostId
HOST_ID=$(head -c 8 /etc/machine-id)

# Get boot UUID
BOOT_UUID=$(blkid -s UUID -o value "${DISK}p1")

# Create optimized configuration
echo -e "${BLUE}[12/12] Creating NixOS configuration...${NC}"
cat > /mnt/etc/nixos/configuration.nix << EOF
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  # ZFS support
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  boot.zfs.requestEncryptionCredentials = true;
  boot.zfs.devNodes = "/dev/disk/by-id";
  networking.hostId = "$HOST_ID";
  
  # ZFS kernel module params for better performance
  boot.kernelParams = [ "zfs.zfs_arc_max=4294967296" ]; # 4GB ARC max
  
  # Boot partition
  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/$BOOT_UUID";
    fsType = "vfat";
  };
  
  # ZFS services
  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "weekly";
  services.zfs.trim.enable = true;
  services.zfs.trim.interval = "weekly";
  
  # Swap
  swapDevices = [{
    device = "/dev/zvol/$POOL_NAME/swap";
  }];
  
  # Hostname
  networking.hostName = "$HOSTNAME";
  
  # Timezone
  time.timeZone = "Asia/Almaty";
  
  # Localization
  i18n.defaultLocale = "en_US.UTF-8";
  
  # Console
  console.keyMap = "us";
  
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
EOF

echo "  - Configuration created"

echo -e "\n${GREEN}=== Installation preparation complete! ===${NC}"
echo -e "${YELLOW}Next steps:${NC}"
echo "1. (Optional) Edit /mnt/etc/nixos/configuration.nix"
echo "2. Run: nixos-install"
echo "3. Set root password when prompted"
echo "4. Run: umount /mnt/boot"
echo "5. Run: zpool export rpool"
echo "6. Reboot: reboot"
echo ""
echo -e "${YELLOW}IMPORTANT:${NC} You will need to enter the ZFS encryption password at boot!"
echo ""
echo -e "${GREEN}ZFS optimizations for NVMe applied:${NC}"
echo "  ✓ ashift=12 (4K sectors optimal for NVMe)"
echo "  ✓ autotrim=on (automatic TRIM for SSD longevity)"
echo "  ✓ compression=zstd (best compression ratio, good performance)"
echo "  ✓ compression=lz4 for /nix (fast compression for binaries)"
echo "  ✓ xattr=sa (extended attributes in system attribute)"
echo "  ✓ dnodesize=auto (optimized metadata)"
echo "  ✓ relatime (reduced write amplification)"
echo "  ✓ encryption=aes-256-gcm (native encryption with AES-NI)"
echo "  ✓ recordsize=16K for /var (optimized for databases/logs)"
echo "  ✓ ARC limited to 4GB (tune in config if needed)"
echo "  ✓ Swap zvol: $SWAP_SIZE with optimized settings"
echo ""
echo -e "${BLUE}Pool status:${NC}"
zpool status $POOL_NAME
