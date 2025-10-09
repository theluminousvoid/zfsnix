{
  description = "NixOS with ZFS";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    
    # Эти модули добавим ПОСЛЕ первой загрузки:
    # home-manager.url = "github:nix-community/home-manager";
    # impermanence.url = "github:nix-community/impermanence";
    # caelestia-shell.url = "github:caelestia-dots/shell";
  };

  outputs = { self, nixpkgs }: {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ 
        ./configuration.nix
        # Модули добавим позже после загрузки
      ];
    };
  };
}
