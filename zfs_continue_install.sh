#!/usr/bin/env bash
set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

POOL_NAME="rpool"
DISK="/dev/nvme0n1"

echo -e "${GREEN}=== Продолжение установки ZFS ===${NC}"

# Проверяем что пул существует
if ! zpool list "$POOL_NAME" &>/dev/null; then
    echo -e "${RED}Ошибка: Пул $POOL_NAME не найден!${NC}"
    exit 1
fi

# Ждём появления zvol устройства
echo -e "${GREEN}Ожидание zvol устройства...${NC}"
sleep 3
udevadm settle

# Проверяем zvol
if [ ! -b "/dev/zvol/$POOL_NAME/swap" ]; then
    echo -e "${YELLOW}Zvol не найден, пытаемся создать заново...${NC}"
    zfs destroy "$POOL_NAME/swap" 2>/dev/null || true
    zfs create -V 16G -b $(getconf PAGESIZE) \
        -o compression=zle \
        -o logbias=throughput \
        -o sync=always \
        -o primarycache=metadata \
        -o secondarycache=none \
        -o com.sun:auto-snapshot=false \
        "$POOL_NAME/swap"
    sleep 3
    udevadm settle
fi

# Форматируем и включаем swap
if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
    echo -e "${GREEN}Настройка swap...${NC}"
    # Отключаем swap если уже включен
    swapoff /dev/zvol/$POOL_NAME/swap 2>/dev/null || true
    # Форматируем
    mkswap -f /dev/zvol/$POOL_NAME/swap
    # Включаем
    swapon /dev/zvol/$POOL_NAME/swap
else
    echo -e "${YELLOW}Предупреждение: Swap zvol не найден, пропускаем...${NC}"
fi

echo -e "${GREEN}Монтирование файловых систем...${NC}"
mount -t zfs "$POOL_NAME/root/nixos" /mnt
mkdir -p /mnt/{home,nix,boot}
mount -t zfs "$POOL_NAME/home" /mnt/home
mount -t zfs "$POOL_NAME/nix" /mnt/nix

# Монтируем var сначала, потом создаём log внутри
mkdir -p /mnt/var
mount -t zfs "$POOL_NAME/var" /mnt/var
mkdir -p /mnt/var/log
mount -t zfs "$POOL_NAME/var/log" /mnt/var/log

mount "${DISK}p1" /mnt/boot

echo -e "${GREEN}Создание снимка начальной установки...${NC}"
zfs snapshot -r "$POOL_NAME@initial"

echo -e "${GREEN}Генерация конфигурации NixOS...${NC}"
nixos-generate-config --root /mnt

# Получаем hostId
HOST_ID=$(head -c 8 /etc/machine-id)

# Создание конфигурации с ZFS
cat > /mnt/etc/nixos/configuration.nix << EOF
{ config, pkgs, ... }:

{
  imports = [ ./hardware-configuration.nix ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  
  # ZFS поддержка
  boot.supportedFilesystems = [ "zfs" ];
  boot.zfs.forceImportRoot = false;
  networking.hostId = "$HOST_ID";
  
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
