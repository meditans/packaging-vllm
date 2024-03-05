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
        };

        inherit (poetry2nix.lib.mkPoetry2Nix { inherit pkgs; })
          mkPoetryEnv defaultPoetryOverrides;

      in {

        devShells.minimal = pkgs.mkShell {
          name = "minimal-dev-shell";
          buildInputs =
            [ (pkgs.python311.withPackages (p: [ p.poetry-core ])) ];
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.ninja
            (mkPoetryEnv {
              python = pkgs.python311;
              projectDir = ./.;
              overrides = defaultPoetryOverrides.extend (self: super: {

                cloudpickle = super.cloudpickle.overridePythonAttrs (old: {
                  buildInputs = (old.buildInputs or [ ]) ++ [ super.flit-core ];
                });

                interegular = super.interegular.overridePythonAttrs (old: {
                  buildInputs = (old.buildInputs or [ ])
                    ++ [ super.setuptools ];
                });

                ninja = super.ninja.overridePythonAttrs (old: {
                  buildInputs = (old.buildInputs or [ ])
                    ++ [ super.scikit-build ];
                });

              });
            })
          ];
        };
      });
}
