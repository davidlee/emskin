{
  description = "emskin — nested Wayland compositor for Emacs";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
  }: let
    systems = ["x86_64-linux" "aarch64-linux"];
    forAll = f:
      nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          overlays = [rust-overlay.overlays.default];
        }));

    # Single source of truth: rust-toolchain.toml (channel + components).
    toolchainFor = pkgs: pkgs.rust-bin.fromRustupToolchainFile ./rust-toolchain.toml;

    # Link-time deps (mirrors .github/workflows/ci.yml's apt list).
    buildInputsFor = pkgs:
      with pkgs; [
        wayland
        libxkbcommon
        udev
        libinput
        libgbm
        seatd
        pixman
        openssl
        libx11
        libxcb
        libxcb-cursor
        libxcb-wm
        fontconfig
        freetype
        libGL
      ];

    # dlopen'd at runtime (winit/EGL/xkb), so they must be on LD_LIBRARY_PATH.
    runtimeLibsFor = pkgs:
      with pkgs; [
        wayland
        libxkbcommon
        libGL
        mesa
        libx11
        libxcursor
        libxi
        libxrandr
      ];

    # Spawned as subprocesses: xwayland-satellite (X apps), dbus-daemon
    # (--dbus-isolated), ffmpeg (recording).
    runtimeBinsFor = pkgs: with pkgs; [xwayland-satellite dbus ffmpeg];
  in {
    packages = forAll (pkgs: let
      toolchain = toolchainFor pkgs;
      rustPlatform = pkgs.makeRustPlatform {
        cargo = toolchain;
        rustc = toolchain;
      };
      cargoToml = builtins.fromTOML (builtins.readFile ./Cargo.toml);
    in rec {
      emskin = rustPlatform.buildRustPackage {
        pname = "emskin";
        version = cargoToml.workspace.package.version;
        src = self;
        cargoLock = {
          lockFile = ./Cargo.lock;
          # smithay is a git dependency (emskin-patches branch).
          allowBuiltinFetchGit = true;
        };
        # Default members: emskin + emskin-bar.
        cargoBuildFlags = ["-p" "emskin" "-p" "emskin-bar"];
        nativeBuildInputs = with pkgs; [pkg-config makeWrapper];
        buildInputs = buildInputsFor pkgs;
        # E2E tests need emez + Xvfb + a GPU-ish env; run them in the devshell.
        doCheck = false;
        # RPATH, not LD_LIBRARY_PATH: a wrapper env var would leak into Emacs
        # and every app emskin spawns.
        postFixup = ''
          for bin in emskin emskin-bar; do
            patchelf --add-rpath ${pkgs.lib.makeLibraryPath (runtimeLibsFor pkgs)} $out/bin/$bin
          done
          wrapProgram $out/bin/emskin \
            --prefix PATH : ${pkgs.lib.makeBinPath (runtimeBinsFor pkgs)}
        '';
        meta = {
          description = "Nested Wayland compositor for Emacs";
          license = pkgs.lib.licenses.gpl3Only;
          mainProgram = "emskin";
        };
      };
      default = emskin;
    });

    devShells = forAll (pkgs: {
      default = pkgs.mkShell {
        nativeBuildInputs = [(toolchainFor pkgs) pkgs.pkg-config];
        buildInputs = buildInputsFor pkgs;
        # E2E test clients (CONTRIBUTING.md) + runtime subprocesses.
        packages = with pkgs;
          [xvfb wl-clipboard xclip dejavu_fonts]
          ++ runtimeBinsFor pkgs;
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath (runtimeLibsFor pkgs);
      };
    });

    formatter = forAll (pkgs: pkgs.alejandra);
  };
}
