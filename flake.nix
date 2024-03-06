{
  description = "Application packaged using poetry2nix";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    poetry2nix = {
      url = "github:nix-community/poetry2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, poetry2nix }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true; # needed for CUDA on Linux
          cudaSupport = true;
        };

        inherit (poetry2nix.lib.mkPoetry2Nix { inherit pkgs; })
          mkPoetryEnv overrides;

      in {

        devShells.minimal =
          (pkgs.mkShell.override { stdenv = pkgs.gcc11Stdenv; }) {
            name = "minimal-dev-shell";
            buildInputs =
              [ (pkgs.python311.withPackages (p: [ p.poetry-core ])) ];
          };

        devShells.default =
          (pkgs.mkShell.override { stdenv = pkgs.gcc11Stdenv; }) {
            buildInputs = [
              pkgs.ninja
              (mkPoetryEnv {
                python = pkgs.python311;
                projectDir = ./.;
                overrides = import ./overrides.nix { inherit overrides; };
              })
            ];
          };
      });
}
