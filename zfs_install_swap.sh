#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== ZFS on Root Installation Script ===${NC}"
echo -e "${YELLOW}Внимание: Этот скрипт полностью сотрёт /dev/nvme0n1!${NC}"
read -p "Продолжить? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

DISK="/dev/nvme0n1"
POOL_NAME="rpool"
HOSTNAME="nixos"
SWAP_SIZE="16G"  # Измените размер swap по необходимости

# Проверка что диск существует
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Ошибка: $DISK не найден!${NC}"
    exit 1
fi

echo -e "${GREEN}Загрузка модуля ZFS...${NC}"
modprobe zfs

echo -e "${GREEN}Очистка диска...${NC}"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 2

echo -e "${GREEN}Создание разделов...${NC}"
# EFI раздел: 1GB
sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI" "$DISK"
# ZFS раздел: остаток диска
sgdisk -n 2:0:0 -t 2:BF00 -c 2:"ZFS" "$DISK"
partprobe "$DISK"
sleep 2

echo -e "${GREEN}Форматирование EFI раздела...${NC}"
mkfs.vfat -F32 -n EFI "${DISK}p1"

echo -e "${GREEN}Создание ZFS пула с шифрованием...${NC}"
echo -e "${YELLOW}Введите пароль для шифрования ZFS:${NC}"
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

echo -e "${GREEN}Создание ZFS datasets...${NC}"

# Root dataset (не монтируется)
zfs create -o mountpoint=none "$POOL_NAME/root"

# NixOS root
zfs create -o mountpoint=legacy "$POOL_NAME/root/nixos"

# Home
zfs create -o mountpoint=legacy "$POOL_NAME/home"

# Nix store (без сжатия для бинарников)
zfs create -o mountpoint=legacy -o compression=lz4 "$POOL_NAME/nix"

# Datasets с отключенным COW для баз данных
zfs create -o mountpoint=legacy -o recordsize=16K -o logbias=throughput "$POOL_NAME/var"
zfs create -o mountpoint=legacy -o recordsize=16K "$POOL_NAME/var/log"

# Swap zvol
echo -e "${GREEN}Создание swap zvol ($SWAP_SIZE)...${NC}"
zfs create -V "$SWAP_SIZE" -b $(getconf PAGESIZE) \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    "$POOL_NAME/swap"

mkswap -f /dev/zvol/$POOL_NAME/swap
swapon /dev/zvol/$POOL_NAME/swap

echo -e "${GREEN}Монтирование файловых систем...${NC}"
mount -t zfs "$POOL_NAME/root/nixos" /mnt
mkdir -p /mnt/{home,nix,var/log,boot}
mount -t zfs "$POOL_NAME/home" /mnt/home
mount -t zfs "$POOL_NAME/nix" /mnt/nix
mount -t zfs "$POOL_NAME/var" /mnt/var
mount -t zfs "$POOL_NAME/var/log" /mnt/var/log
mount "${DISK}p1" /mnt/boot

echo -e "${GREEN}Создание снимка начальной установки...${NC}"
zfs snapshot -r "$POOL_NAME@initial"

echo -e "${GREEN}Генерация конфигурации NixOS...${NC}"
nixos-generate-config --root /mnt

# Создание минимальной конфигурации с ZFS
cat > /mnt/etc/nixos/configuration.nix << 'EOF'
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  # ZFS поддержка
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "$(head -c 8 /etc/machine-id)";
  
  # ZFS services
  services.zfs.autoScrub.enable = true;
  services.zfs.autoScrub.interval = "weekly";
  services.zfs.trim.enable = true;
  
  # Swap
  swapDevices = [{
    device = "/dev/zvol/rpool/swap";
  }];
  
  # Hostname
  networking.hostName = "nixos";
  
  # Timezone
  time.timeZone = "Asia/Almaty";
  
  # Localization
  i18n.defaultLocale = "ru_RU.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS = "ru_RU.UTF-8";
    LC_IDENTIFICATION = "ru_RU.UTF-8";
    LC_MEASUREMENT = "ru_RU.UTF-8";
    LC_MONETARY = "ru_RU.UTF-8";
    LC_NAME = "ru_RU.UTF-8";
    LC_NUMERIC = "ru_RU.UTF-8";
    LC_PAPER = "ru_RU.UTF-8";
    LC_TELEPHONE = "ru_RU.UTF-8";
    LC_TIME = "ru_RU.UTF-8";
  };
  
  # Console (terminal) остаётся английским
  console = {
    keyMap = "us";
  };
  
  # Users
  users.users.luminous = {
    isNormalUser = true;
    initialPassword = "2477";
    extraGroups = [ "wheel" "networkmanager" "video" ];
  };
  
  # Packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    git
  ];
  
  # NetworkManager
  networking.networkmanager.enable = true;
  
  # SSH
  services.openssh.enable = true;
  
  system.stateVersion = "24.05";
}
EOF

echo -e "${GREEN}=== Установка завершена! ===${NC}"
echo -e "${YELLOW}Следующие шаги:${NC}"
echo "1. Отредактируйте /mnt/etc/nixos/configuration.nix"
echo "2. Добавьте пользователей и другие настройки"
echo "3. Выполните: nixos-install"
echo "4. Установите root пароль когда попросит"
echo "5. Перезагрузитесь: reboot"
echo ""
echo -e "${YELLOW}Важно:${NC} При загрузке нужно будет ввести пароль для расшифровки ZFS!"
echo ""
echo -e "${GREEN}Оптимизации ZFS для NVMe применены:${NC}"
echo "- ashift=12 (4K sectors)"
echo "- autotrim=on (TRIM для SSD)"
echo "- compression=zstd (лучшее сжатие)"
echo "- xattr=sa (быстрые расширенные атрибуты)"
echo "- dnodesize=auto (оптимизация метаданных)"
echo "- encryption=aes-256-gcm (нативное шифрование)"
echo "- swap zvol: $SWAP_SIZE"
