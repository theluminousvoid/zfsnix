#!/usr/bin/env bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# Configuration
DISK="/dev/nvme0n1"
POOL_NAME="rpool"
HOSTNAME="nixos"
SWAP_SIZE="32G"
USERNAME="luminous"
USER_PASSWORD="2477"

echo -e "${MAGENTA}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${MAGENTA}║    Ultimate ZFS NixOS with Impermanence & Caelestia Shell   ║${NC}"
echo -e "${MAGENTA}║                   Optimized for 32GB RAM                     ║${NC}"
echo -e "${MAGENTA}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}⚠️  WARNING: This will completely ERASE $DISK!${NC}"
echo -e "${CYAN}Features:${NC}"
echo "  • Full disk encryption with ZFS"
echo "  • Impermanence (rollback on reboot)"
echo "  • Caelestia shell with flakes"
echo "  • Docker/Podman optimized datasets"
echo "  • Advanced monitoring & security"
echo ""
read -p "Continue? (yes/no): " confirm
[[ "$confirm" != "yes" ]] && exit 1

# Check disk exists
if [ ! -b "$DISK" ]; then
    echo -e "${RED}Error: $DISK not found!${NC}"
    exit 1
fi

# Cleanup previous installations
echo -e "${BLUE}[1/15] Cleaning up previous installations...${NC}"
fuser -km /mnt 2>/dev/null || true
sleep 2
swapoff -a 2>/dev/null || true
swapoff /dev/zvol/$POOL_NAME/swap 2>/dev/null || true
zfs unmount -a 2>/dev/null || true
umount -R /mnt 2>/dev/null && echo "  - Filesystems unmounted" || echo "  - No filesystems to unmount"
zpool export -f $POOL_NAME 2>/dev/null && echo "  - Pool exported" || echo "  - No pool to export"
rm -f /dev/zvol/$POOL_NAME/* 2>/dev/null || true
sleep 3

# Load ZFS module with parameters
echo -e "${BLUE}[2/15] Loading ZFS kernel module with optimized parameters...${NC}"
if lsmod | grep -q zfs; then
    echo "  - ZFS module already loaded, setting parameters..."
else
    modprobe zfs
    echo "  - ZFS module loaded"
fi

echo 32 > /sys/module/zfs/parameters/zvol_threads 2>/dev/null || true
echo 8 > /sys/module/zfs/parameters/zvol_request_sync 2>/dev/null || true
echo "  - Set zvol_threads=32, zvol_request_sync=8"

# Partition disk
echo -e "${BLUE}[3/15] Partitioning disk...${NC}"
sgdisk --zap-all "$DISK"
partprobe "$DISK"
sleep 3

sgdisk -n 1:0:+1G -t 1:EF00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0 -t 2:BF00 -c 2:"ZFS" "$DISK"
partprobe "$DISK"
sleep 3
echo "  - Partitions created: ${DISK}p1 (EFI), ${DISK}p2 (ZFS)"

udevadm settle --timeout=30
sleep 2

# Format EFI
echo -e "${BLUE}[4/15] Formatting EFI partition...${NC}"
mkfs.vfat -F32 -n EFI "${DISK}p1"
echo "  - EFI partition formatted"

# Create ZFS pool with encryption
echo -e "${BLUE}[5/15] Creating encrypted ZFS pool...${NC}"
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

# Create datasets
echo -e "${BLUE}[6/15] Creating ZFS datasets with optimized layout...${NC}"

# Root datasets
zfs create -o mountpoint=none "$POOL_NAME/root"
zfs create -o mountpoint=/ -o canmount=noauto "$POOL_NAME/root/nixos"
echo "  ✓ Root filesystem"

# Persistent data (survives impermanence)
zfs create -o mountpoint=/persist "$POOL_NAME/persist"
echo "  ✓ Persistent storage"

# Home
zfs create -o mountpoint=/home "$POOL_NAME/home"
echo "  ✓ Home directories"

# Nix store
zfs create -o mountpoint=/nix -o compression=lz4 "$POOL_NAME/nix"
echo "  ✓ Nix store (lz4)"

# Var datasets
zfs create -o mountpoint=/var -o recordsize=16K -o logbias=throughput "$POOL_NAME/var"
zfs create -o mountpoint=/var/log -o recordsize=16K "$POOL_NAME/var/log"
echo "  ✓ System logs"

# Docker optimized dataset
zfs create -o mountpoint=/var/lib/docker -o recordsize=64K "$POOL_NAME/docker"
echo "  ✓ Docker storage (64K blocks)"

# Virtual machines dataset
zfs create -o mountpoint=/var/lib/libvirt -o recordsize=64K \
    -o primarycache=metadata "$POOL_NAME/vms"
echo "  ✓ VM storage"

# Database dataset
zfs create -o mountpoint=/var/lib/postgresql -o recordsize=8K \
    -o logbias=throughput -o primarycache=metadata "$POOL_NAME/postgres"
echo "  ✓ PostgreSQL (8K pages)"

# Temporary files dataset
zfs create -o mountpoint=/tmp -o compression=lz4 \
    -o sync=disabled -o setuid=off -o devices=off "$POOL_NAME/tmp"
echo "  ✓ Temporary files (sync disabled)"

# Downloads (no snapshots)
zfs create -o mountpoint=/home/$USERNAME/Downloads \
    -o com.sun:auto-snapshot=false "$POOL_NAME/downloads"
echo "  ✓ Downloads (no snapshots)"

# Wait for ZFS to settle
echo -e "${BLUE}[7/15] Waiting for ZFS to settle...${NC}"
sleep 5
sync
zpool sync "$POOL_NAME"
udevadm settle --timeout=30

# Mount filesystems
echo -e "${BLUE}[8/15] Mounting filesystems...${NC}"
zpool export "$POOL_NAME"
sleep 3
zpool import -d /dev/disk/by-id -N -R /mnt "$POOL_NAME"
echo "  - Pool imported"

zfs load-key -a
sleep 2

# Mount in correct order
zfs mount "$POOL_NAME/root/nixos"
sleep 1
zfs mount "$POOL_NAME/persist"
zfs mount "$POOL_NAME/home"
zfs mount "$POOL_NAME/nix"
zfs mount "$POOL_NAME/var"
zfs mount "$POOL_NAME/var/log"
zfs mount "$POOL_NAME/docker"
zfs mount "$POOL_NAME/vms"
zfs mount "$POOL_NAME/postgres"
zfs mount "$POOL_NAME/tmp"
# Downloads will be mounted after user creation

mkdir -p /mnt/boot
mount "${DISK}p1" /mnt/boot
echo "  - All filesystems mounted"

# Create swap zvol
echo -e "${BLUE}[9/15] Creating swap zvol ($SWAP_SIZE)...${NC}"
zfs create -V "$SWAP_SIZE" -b $(getconf PAGESIZE) \
    -o compression=zle \
    -o logbias=throughput \
    -o sync=always \
    -o primarycache=metadata \
    -o secondarycache=none \
    -o com.sun:auto-snapshot=false \
    -o org.freebsd:swap=on \
    "$POOL_NAME/swap"

for i in {1..30}; do
    if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
        break
    fi
    sleep 1
done

udevadm settle --timeout=30
sleep 2

if [ -b "/dev/zvol/$POOL_NAME/swap" ]; then
    mkswap -f /dev/zvol/$POOL_NAME/swap
    echo "  - Swap formatted (will activate on boot)"
fi

# Create blank snapshot for impermanence
echo -e "${BLUE}[10/15] Creating blank snapshot for impermanence...${NC}"
zfs snapshot "$POOL_NAME/root/nixos@blank"
echo "  - Blank snapshot created for rollback"

# Backup encryption keys
echo -e "${BLUE}[11/15] Backing up encryption keys...${NC}"
mkdir -p /mnt/persist/zfs-keys-backup
zfs get keylocation,keyformat,encryption "$POOL_NAME" > /mnt/persist/zfs-keys-backup/pool-info.txt
echo "CRITICAL: Save your passphrase separately!" > /mnt/persist/zfs-keys-backup/README.txt
echo "Pool creation date: $(date)" >> /mnt/persist/zfs-keys-backup/README.txt
chmod 700 /mnt/persist/zfs-keys-backup
echo "  - Keys info saved to /persist/zfs-keys-backup/"

# Generate initial NixOS config
echo -e "${BLUE}[12/15] Generating NixOS hardware configuration...${NC}"
nixos-generate-config --root /mnt
echo "  - Hardware configuration generated"

# Get hostId
HOST_ID=$(head -c 8 /etc/machine-id)

# Create flake.nix
echo -e "${BLUE}[13/15] Creating flake configuration with Caelestia shell...${NC}"
cat > /mnt/etc/nixos/flake.nix << 'FLAKEEOF'
{
  description = "NixOS with ZFS, Impermanence, and Caelestia Shell";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    impermanence.url = "github:nix-community/impermanence";
    
    caelestia-shell = {
      url = "github:caelestia-dots/shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, impermanence, caelestia-shell, ... }@inputs: {
    nixosConfigurations.HOSTNAME_PLACEHOLDER = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit inputs; };
      modules = [
        ./configuration.nix
        home-manager.nixosModules.home-manager
        impermanence.nixosModules.impermanence
      ];
    };
  };
}
FLAKEEOF

# Create main configuration
echo -e "${BLUE}[14/15] Creating advanced NixOS configuration...${NC}"
cat > /mnt/etc/nixos/configuration.nix << 'NIXEOF'
{ config, pkgs, lib, inputs, ... }:

{
  imports = [ 
    ./hardware-configuration.nix
  ];

  # Enable flakes
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # Bootloader
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  boot.loader.timeout = 10;
  
  # ZFS support
  boot.supportedFilesystems = [ "zfs" ];
  boot.initrd.supportedFilesystems = [ "zfs" ];
  boot.zfs.devNodes = "/dev/disk/by-id";
  boot.zfs.forceImportRoot = false;
  boot.zfs.requestEncryptionCredentials = [ "rpool/root/nixos" ];
  
  # Impermanence - rollback root on boot
  boot.initrd.postDeviceCommands = lib.mkAfter ''
    zfs rollback -r rpool/root/nixos@blank
  '';
  
  # Host configuration
  networking.hostId = "HOSTID_PLACEHOLDER";
  networking.hostName = "HOSTNAME_PLACEHOLDER";
  
  # ZFS kernel params for 32GB RAM
  boot.kernelParams = [ 
    "zfs.zfs_arc_max=17179869184"    # 16GB ARC max
    "zfs.zfs_arc_min=4294967296"     # 4GB ARC min
    "zfs.zvol_threads=32"
    "zfs.zvol_request_sync=8"
    "zfs.zfs_taskq_batch_pct=75"
    "zfs.zvol_inhibit_dev=0"
    "zfs.zfs_vdev_async_write_min_active=8"
    "zfs.zfs_vdev_async_write_max_active=32"
    "zfs.l2arc_noprefetch=0"
    "zfs.l2arc_write_max=134217728"
  ];
  
  boot.initrd.kernelModules = [ "zfs" ];
  
  # Kernel sysctl optimizations
  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "vm.min_free_kbytes" = 262144;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
    "vm.vfs_cache_pressure" = 50;
    "kernel.unprivileged_userns_clone" = 0;
    "net.core.bpf_jit_harden" = 2;
    "kernel.ftrace_enabled" = false;
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
  
  # ZED monitoring
  services.zfs.zed = {
    enable = true;
    settings = {
      ZED_DEBUG_LOG = "/var/log/zed.debug.log";
      ZED_EMAIL_ADDR = "root";
      ZED_NOTIFY_INTERVAL_SECS = 3600;
    };
  };
  
  # Sanoid for advanced snapshots
  services.sanoid = {
    enable = true;
    datasets = {
      "rpool/home" = {
        hourly = 48;
        daily = 14;
        monthly = 6;
        yearly = 1;
      };
      "rpool/persist" = {
        hourly = 24;
        daily = 30;
        monthly = 12;
        yearly = 2;
      };
      "rpool/root/nixos" = {
        hourly = 0;  # Impermanence handles this
        daily = 0;
        monthly = 0;
      };
    };
  };
  
  # Swap
  swapDevices = [{
    device = "/dev/zvol/rpool/swap";
    priority = 100;
    randomEncryption.enable = false;
  }];
  
  # Zram for additional compressed swap
  zramSwap = {
    enable = true;
    memoryPercent = 25;  # 8GB zram
    algorithm = "zstd";
  };
  
  # Tmpfs for build directory
  boot.tmpOnTmpfs = false;  # We use ZFS dataset instead
  
  # Timezone and locale
  time.timeZone = "Asia/Almaty";
  i18n.defaultLocale = "en_US.UTF-8";
  console.keyMap = "us";
  
  # Nix optimizations
  nix.settings = {
    auto-optimise-store = true;
    max-jobs = 8;
    cores = 4;
    substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };
  
  # Garbage collection
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  
  # Performance
  powerManagement.cpuFreqGovernor = "performance";
  
  services.udev.extraRules = ''
    ACTION=="add|change", KERNEL=="nvme[0-9]*", ATTR{queue/scheduler}="none"
    ACTION=="add|change", KERNEL=="sd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="mq-deadline"
  '';
  
  # Security
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
    trustedInterfaces = [ "lo" ];
  };
  
  services.fail2ban = {
    enable = true;
    maxretry = 3;
  };
  
  # SSH
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };
  
  # Monitoring
  services.smartd = {
    enable = true;
    autodetect = true;
  };
  
  # Docker
  virtualisation.docker = {
    enable = true;
    storageDriver = "zfs";
    daemon.settings = {
      storage-opts = [
        "zfs.fsname=rpool/docker"
      ];
    };
  };
  
  # Users
  users.users.USERNAME_PLACEHOLDER = {
    isNormalUser = true;
    initialPassword = "USER_PASSWORD_PLACEHOLDER";
    extraGroups = [ "wheel" "networkmanager" "video" "docker" ];
    shell = pkgs.zsh;
  };
  
  # System packages
  environment.systemPackages = with pkgs; [
    vim
    git
    htop
    wget
    curl
    tmux
    zfs
    sanoid
    inputs.caelestia-shell.packages.x86_64-linux.with-cli  # Caelestia with CLI
    docker-compose
    ncdu
    tree
    rsync
    ripgrep
    fd
    bat
    eza
    zoxide
    fzf
    jq
  ];
  
  # ZSH as default shell
  programs.zsh.enable = true;
  
  # NetworkManager
  networking.networkmanager.enable = true;
  
  # Persistent directories and files
  environment.persistence."/persist" = {
    directories = [
      "/var/log"
      "/var/lib/bluetooth"
      "/var/lib/systemd/coredump"
      "/etc/NetworkManager/system-connections"
    ];
    files = [
      "/etc/machine-id"
      "/etc/ssh/ssh_host_ed25519_key"
      "/etc/ssh/ssh_host_ed25519_key.pub"
      "/etc/ssh/ssh_host_rsa_key"
      "/etc/ssh/ssh_host_rsa_key.pub"
    ];
  };
  
  # Home Manager configuration
  home-manager = {
    useGlobalPkgs = true;
    useUserPackages = true;
    users.USERNAME_PLACEHOLDER = { pkgs, ... }: {
      home.stateVersion = "24.05";
      
      # Caelestia shell integration
      programs.zsh = {
        enable = true;
        enableAutosuggestions = true;
        syntaxHighlighting.enable = true;
        
        initExtra = ''
          # Run Caelestia shell
          if [[ $- == *i* ]] && command -v caelestia-shell &>/dev/null; then
            exec caelestia-shell
          fi
        '';
        
        shellAliases = {
          ll = "eza -la";
          la = "eza -la";
          ls = "eza";
          cat = "bat";
          find = "fd";
          grep = "rg";
          cd = "z";
        };
      };
      
      programs.git = {
        enable = true;
        userName = "Your Name";
        userEmail = "your@email.com";
        extraConfig = {
          init.defaultBranch = "main";
          core.editor = "vim";
        };
      };
      
      programs.direnv = {
        enable = true;
        enableZshIntegration = true;
        nix-direnv.enable = true;
      };
      
      programs.starship = {
        enable = true;
        enableZshIntegration = true;
      };
      
      # Persistent user data
      home.persistence."/persist/home/USERNAME_PLACEHOLDER" = {
        directories = [
          "Documents"
          "Pictures"
          "Videos"
          "Music"
          "Projects"
          ".ssh"
          ".gnupg"
          ".config"
          ".local"
          ".cache"
        ];
        allowOther = true;
      };
    };
  };
  
  system.stateVersion = "24.05";
}
NIXEOF

# Replace placeholders
sed -i "s/HOSTID_PLACEHOLDER/$HOST_ID/g" /mnt/etc/nixos/configuration.nix
sed -i "s/HOSTNAME_PLACEHOLDER/$HOSTNAME/g" /mnt/etc/nixos/configuration.nix /mnt/etc/nixos/flake.nix
sed -i "s/USERNAME_PLACEHOLDER/$USERNAME/g" /mnt/etc/nixos/configuration.nix
sed -i "s/USER_PASSWORD_PLACEHOLDER/$USER_PASSWORD/g" /mnt/etc/nixos/configuration.nix

# Create persistent directories structure
echo -e "${BLUE}[15/15] Setting up persistent storage structure...${NC}"
mkdir -p /mnt/persist/etc/ssh
mkdir -p /mnt/persist/etc/NetworkManager/system-connections
mkdir -p /mnt/persist/home/$USERNAME/{Documents,Pictures,Videos,Music,Projects,.ssh,.gnupg,.config,.local,.cache}
chown -R 1000:100 /mnt/persist/home/$USERNAME
chmod 700 /mnt/persist/home/$USERNAME/.ssh
chmod 700 /mnt/persist/home/$USERNAME/.gnupg

# Generate SSH host keys in persistent storage
ssh-keygen -A -f /mnt/persist

# Set cachefile
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"
mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache 2>/dev/null || true

# Final status
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║           Installation Preparation Complete! 🎉              ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}📊 System Overview:${NC}"
echo "  • CPU: Optimized for performance governor"
echo "  • RAM: 32GB (16GB ARC + 8GB Zram + 8GB Apps)"
echo "  • Swap: 32GB zvol + 8GB zram"
echo "  • Root: Impermanence (resets on reboot)"
echo "  • Shell: Caelestia with CLI enabled"
echo ""
echo -e "${CYAN}📁 ZFS Dataset Layout:${NC}"
df -h /mnt /mnt/persist /mnt/home /mnt/nix /mnt/var /mnt/boot | column -t
echo ""
echo -e "${CYAN}🔒 Security Features:${NC}"
echo "  ✓ Full disk encryption (AES-256-GCM)"
echo "  ✓ Impermanence (stateless root)"
echo "  ✓ Firewall + Fail2ban"
echo "  ✓ SSH key-only authentication"
echo "  ✓ Hardened kernel parameters"
echo ""
echo -e "${CYAN}🚀 Advanced Features:${NC}"
echo "  ✓ Docker with ZFS backend"
echo "  ✓ Sanoid snapshot management"
echo "  ✓ ZED monitoring daemon"
echo "  ✓ SMART disk monitoring"
echo "  ✓ Nix flakes enabled"
echo "  ✓ Home Manager integrated"
echo ""
echo -e "${YELLOW}📋 Next Steps:${NC}"
echo "1. Review configuration: vim /mnt/etc/nixos/configuration.nix"
echo "2. Install system: nixos-install --flake /mnt/etc/nixos#$HOSTNAME"
echo "3. Set root password when prompted"
echo "4. Reboot: reboot"
echo ""
echo -e "${RED}⚠️  IMPORTANT:${NC}"
echo "  • ZFS password required at boot"
echo "  • Root filesystem resets on reboot (impermanence)"
echo "  • User data persists in /persist"
echo "  • First boot may take longer (building Caelestia)"
echo ""
echo -e "${MAGENTA}💡 Post-Installation:${NC}"
echo "  • Add your SSH keys to /persist/home/$USERNAME/.ssh/"
echo "  • Configure git: git config --global user.name && user.email"
echo "  • Enable additional services as needed"
echo "  • Consider adding L2ARC: zpool add rpool cache /dev/sda"
echo "  • Create backup pool: zpool create backup /dev/sdb"
echo ""
echo -e "${GREEN}Enjoy your ultimate NixOS setup! 🚀${NC}"