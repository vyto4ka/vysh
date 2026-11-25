{
  description = "vysh — minimal SSH manager with tabs, terminal and SFTP (Material 3)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      vyshPackage = pkgs.callPackage ./packaging/nix/package.nix { };

      mkProgramModule =
        targetOption:
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.vysh;
          defaultPkg = self.packages.${pkgs.stdenv.hostPlatform.system}.vysh or (
            pkgs.callPackage ./packaging/nix/package.nix { }
          );
        in
        {
          options.programs.vysh = {
            enable = lib.mkEnableOption "vysh SSH manager";
            package = lib.mkOption {
              type = lib.types.package;
              default = defaultPkg;
              description = "The vysh package to install.";
            };
          };

          config = lib.mkIf cfg.enable (
            lib.setAttrByPath targetOption [ cfg.package ]
          );
        };
    in
    {
      packages.${system} = {
        vysh = vyshPackage;
        default = vyshPackage;
      };

      apps.${system} = {
        vysh = {
          type = "app";
          program = "${vyshPackage}/bin/vysh";
          meta = vyshPackage.meta;
        };
        default = self.apps.${system}.vysh;
      };

      overlays.default = final: _prev: {
        vysh = final.callPackage ./packaging/nix/package.nix { };
      };

      nixosModules = {
        vysh = mkProgramModule [ "environment" "systemPackages" ];
        default = self.nixosModules.vysh;
      };

      homeManagerModules = {
        vysh = mkProgramModule [ "home" "packages" ];
        default = self.homeManagerModules.vysh;
      };

      checks.${system} = {
        package = vyshPackage;
      };
    };
}
