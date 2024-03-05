{ defaultPoetryOverrides }:
let
  # Make a fixed-output derivation with a file's contents; can be used to avoid making something depend on the entire
  # lmql source tree when it only needs one file.
  makeFOD = pkgs: smallSourceFile:
    pkgs.runCommand (builtins.baseNameOf smallSourceFile) {
      outputHashMode = "flat";
      outputHashAlgo = "sha256";
      outputHash = builtins.hashFile "sha256" smallSourceFile;
      inherit smallSourceFile;
    } ''
      rmdir -- "$out" ||:
      cp -- "$smallSourceFile" "$out"
    '';

  # Some prebuilt operations we often need to do to make Python packages build

  # The lazy version: Give up on building it from source altogether and use a binary
  preferWheel = { name, final, prev, pkg }:
    pkg.override { preferWheel = true; };

  resolveDep = { name, final, prev, pkg }@args:
    (dep:
      if builtins.isString dep then
        builtins.getAttr dep final
      else if builtins.isFunction dep then
        (dep args)
      else
        dep);

  # Add extra inputs needed to build from source; often things like setuptools or hatchling not included upstream
  addBuildInputs = extraBuildInputs:
    { name, final, prev, pkg }@args:
    pkg.overridePythonAttrs (old: {
      buildInputs = (old.buildInputs or [ ])
        ++ (builtins.map (resolveDep args) extraBuildInputs);
    });

  # Not sure what pytorch is doing such that its libtorch_global_deps.so dependency on libstdc++ isn't detected by autoPatchelfFixup, but...
  addLibstdcpp = libToPatch:
    { name, final, prev, pkg }@args:
    if final.pkgs.stdenv.isDarwin then
      pkg.overridePythonAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          while IFS= read -r -d "" tgt; do
            cmd=( ${final.pkgs.patchelf}/bin/patchelf --add-rpath ${final.pkgs.stdenv.cc.cc.lib}/lib --add-needed libstdc++.so "$tgt" )
            echo "Running: ''${cmd[*]@Q}" >&2
            "''${cmd[@]}"
          done < <(find "$out" -type f -name ${
            final.pkgs.lib.escapeShellArg libToPatch
          } -print0)
        '';
      })
    else
      pkg;

  # Add extra build-time inputs needed to build from source
  addNativeBuildInputs = extraBuildInputs:
    { name, final, prev, pkg }@args:
    pkg.overridePythonAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ])
        ++ (builtins.map (resolveDep args) extraBuildInputs);
    });

  addPatchelfSearchPath = libSearchPathDeps:
    { name, final, prev, pkg }@args:
    let
      opsForDep = dep: ''
        while IFS= read -r -d "" dir; do
          addAutoPatchelfSearchPath "$dir"
        done < <(find ${
          resolveDep args dep
        } -type f -name 'lib*.so' -printf '%h\0' | sort -zu)
      '';
    in pkg.overridePythonAttrs (old: {
      prePatch = (old.prePatch or "") + (final.pkgs.lib.concatLines
        (builtins.map opsForDep libSearchPathDeps));
    });

  # Rust packages need extra build-time dependencies; and if the upstream repo didn't package a Cargo.lock file we need to add one for them
  asRustBuild = { name, final, prev, pkg }:
    let
      lockFilePath = ./cargo-deps/. + "/${pkg.pname}-${pkg.version}-Cargo.lock";
      lockFile = makeFOD prev.pkgs lockFilePath;
      haveLockFileOverride = builtins.pathExists lockFilePath;
    in pkg.overridePythonAttrs (old:
      {
        buildInputs = (old.buildInputs or [ ])
          ++ [ final.setuptools final.setuptools-rust final.pkgs.iconv ]
          ++ final.pkgs.lib.optional final.pkgs.stdenv.isDarwin
          final.pkgs.darwin.apple_sdk.frameworks.Security;
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [
          final.pkgs.cargo
          final.pkgs.rustc
          final.pkgs.rustPlatform.cargoSetupHook
        ];
      } // (if haveLockFileOverride then {
        cargoDeps =
          final.pkgs.rustPlatform.importCargoLock { inherit lockFile; };
        prePatch = ''
          cp -- ${lockFile} ./Cargo.lock
          ${old.prePatch or ""}
        '';
      } else
        { }));

  withCudaPkgs = { name, final, prev, pkg }@args:
    if final.pkgs.stdenv.isLinux then
      addBuildInputs [
        final.pkgs.cudaPackages.cuda_cudart
        final.pkgs.cudaPackages.cuda_cupti
        final.pkgs.cudaPackages.cuda_nvrtc
        final.pkgs.cudaPackages.cuda_nvtx
        final.pkgs.cudaPackages.cudnn
        final.pkgs.cudaPackages.nccl
        final.pkgs.cudaPackages.libcublas
        final.pkgs.cudaPackages.libcufft
        final.pkgs.cudaPackages.libcurand
        final.pkgs.cudaPackages.libcusparse
        final.triton
      ] args
    else
      pkg;

  withCudaInputs = { name, final, prev, pkg }@args:
    if final.pkgs.stdenv.isLinux then
      addBuildInputs [
        final.nvidia-cublas-cu12
        final.nvidia-cuda-cupti-cu12
        final.nvidia-cuda-nvrtc-cu12
        final.nvidia-cuda-runtime-cu12
        final.nvidia-cudnn-cu12
        final.nvidia-cufft-cu12
        final.nvidia-curand-cu12
        final.nvidia-cusolver-cu12
        # final.nvidia-cusparse-cu12
        final.nvidia-nccl-cu12
        final.nvidia-nvtx-cu12
        final.pkgs.cudaPackages.cuda_cudart
        final.pkgs.cudaPackages.cuda_cupti
        final.pkgs.cudaPackages.cuda_nvrtc
        final.pkgs.cudaPackages.cuda_nvtx
        final.pkgs.cudaPackages.cudnn
        final.pkgs.cudaPackages.nccl
        final.pkgs.cudaPackages.libcublas
        final.pkgs.cudaPackages.libcufft
        final.pkgs.cudaPackages.libcurand
        final.pkgs.cudaPackages.libcusparse
        final.triton
      ] args
    else
      pkg;

  composeOpPair = opLeft: opRight:
    { name, final, prev, pkg }@argsIn:
    let firstResult = (opLeft argsIn);
    in opRight {
      inherit name final;
      prev = prev // { "${name}" = firstResult; };
      pkg = firstResult;
    };

  composeIdentity = { name, final, prev, pkg }: pkg;

  composeOps = builtins.foldl' composeOpPair composeIdentity;

  # Python eggs only record runtime dependencies, not build dependencies; so we record build deps that aren't autodetected here.
  buildOps = let
    pkg-config = { final, ... }: final.pkgs.pkg-config;
    openssl = { final, ... }: final.pkgs.openssl;
  in {
    accelerate = composeOps [
      withCudaInputs
      (addBuildInputs [ "filelock" "jinja2" "networkx" "setuptools" "sympy" ])
    ];
    accessible-pygments = addBuildInputs [ "setuptools" ];
    aiohttp-sse-client =
      composeOps [ (addBuildInputs [ "pytest" "pytest-runner" "setuptools" ]) ];
    auto-gptq =
      composeOps [ withCudaInputs (addPatchelfSearchPath [ "torch" ]) ];
    cmake = composeOps [
      preferWheel
      (addBuildInputs [ "setuptools" "scikit-build" ])
    ];
    optimum = composeOps [ withCudaInputs (addBuildInputs [ "setuptools" ]) ];
    pandas = addBuildInputs [ "versioneer" "tomli" ];
    peft = withCudaInputs;
    pandoc = addBuildInputs [ "setuptools" ];
    pydata-sphinx-theme = preferWheel;
    rouge = addBuildInputs [ "setuptools" ];
    safetensors = asRustBuild; # preferWheel
    shibuya = addBuildInputs [ "setuptools" ];
    sphinx-book-theme = preferWheel;
    sphinx-theme-builder = addBuildInputs [ "filit-core" ];
    tiktoken = preferWheel; # asRustBuild;
    tokenizers =
      preferWheel; # composeOps [ asRustBuild (addBuildInputs [openssl]) (addNativeBuildInputs [ pkg-config ]) ];
    torch = composeOps [
      withCudaInputs
      (addBuildInputs [ "filelock" "jinja2" "networkx" "sympy" ])
      (addLibstdcpp "libtorch_global_deps.so")
    ];
    urllib3 = addBuildInputs [ "hatchling" ];
    interegular = addBuildInputs [ "setuptools" ];
    cloudpickle = addBuildInputs [ "flit-core" ];
    ninja = addBuildInputs [ "scikit-build" ];
    nvidia-cusparse-cu12 = withCudaPkgs;
  };
  buildOpsOverlay = (final: prev:
    builtins.mapAttrs (package: op:
      (op {
        inherit final prev;
        name = package;
        pkg = builtins.getAttr package prev;
      })) buildOps);
in defaultPoetryOverrides.extend buildOpsOverlay
