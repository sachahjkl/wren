{
  description = "Wren, a web browser where WebAssembly runs everything, JavaScript included";

  inputs = {
    # the toolkit and Lexbor are submodules: the package builds from them
    self.submodules = true;
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    rust-overlay = {
      url = "https://flakehub.com/f/oxalica/rust-overlay/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks = {
      url = "https://flakehub.com/f/cachix/git-hooks.nix/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    rust-overlay,
    git-hooks,
  }: let
    system = "x86_64-linux";
    inherit (nixpkgs) lib;
    pkgs = import nixpkgs {
      inherit system;
      overlays = [rust-overlay.overlays.default];
      # PolyForm Strict: this flake's own package only
      config.allowUnfreePredicate = p: lib.getName p == "wren";
    };

    # The Rust of the CI (.github/actions/setup/action.yml).
    rust = pkgs.rust-bin.stable."1.99.1";

    # What the browser opens with dlopen when it makes a window or a GPU device, beside what it links (docs/portability.md).
    # src/desktop/nixos_linux.odin installs the same list for a downloaded copy (the test nixos_libraries_follow_the_flake).
    runtimeLibs = with pkgs; [
      alsa-lib
      fontconfig
      freetype
      libopus
      libxkbcommon
      vulkan-loader
      wayland
      libxcb
      libxcb-cursor
      libglvnd
      libfido2
    ];

    # The compiler this tree is written for (odin.version; the release and SHA-256 of .github/actions/setup/action.yml).
    odinTag = "dev-2026-11a";
    odin = pkgs.stdenv.mkDerivation {
      pname = "odin";
      version = odinTag;
      src = pkgs.fetchurl {
        url = "https://github.com/odin-lang/Odin/releases/download/${odinTag}/odin-linux-amd64-${odinTag}.tar.gz";
        sha256 = "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618";
      };
      nativeBuildInputs = [pkgs.autoPatchelfHook pkgs.makeWrapper];
      buildInputs = [pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.libxml2 pkgs.zstd pkgs.ncurses];
      dontBuild = true;
      dontStrip = true;
      sourceRoot = ".";
      # the libraries of vendor/ that Wren does not use (raylib wants X11...)
      autoPatchelfIgnoreMissingDeps = true;
      installPhase = ''
        runHook preInstall
        root="$(dirname "$(find . -maxdepth 3 -name odin -type f | head -1)")"
        mkdir -p "$out/lib/odin" "$out/bin"
        cp -r "$root"/. "$out/lib/odin/"
        makeWrapper "$out/lib/odin/odin" "$out/bin/odin" \
          --set-default ODIN_ROOT "$out/lib/odin" \
          --prefix PATH : ${lib.makeBinPath [pkgs.clang pkgs.lld]}
        runHook postInstall
      '';
    };

    # What wrentool fetches (src/tools/wrentool/deps/fetch.odin: the same URLs and SHA-256), put where it looks for them
    # first, so the build makes no request.
    wasmtimeVersion = "49.0.3";
    wasmtimeArchive = pkgs.fetchurl {
      url = "https://github.com/bytecodealliance/wasmtime/releases/download/v${wasmtimeVersion}/wasmtime-v${wasmtimeVersion}-x86_64-linux-c-api.tar.xz";
      sha256 = "49c9641ac1f6158ed90404115315b36a9ae68338acda16fcf00f0819622ccd97";
    };
    wasmtimeLicense = pkgs.fetchurl {
      url = "https://raw.githubusercontent.com/bytecodealliance/wasmtime/v${wasmtimeVersion}/LICENSE";
      sha256 = "268872b9816f90fd8e85db5a28d33f8150ebb8dd016653fb39ef1f94f2686bc5";
    };
    wgpuArchive = pkgs.fetchurl {
      url = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-linux-x86_64-release.zip";
      sha256 = "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a";
    };

    # APP_VERSION of src/browser/about.odin
    version = let
      line = lib.findFirst (lib.hasPrefix "APP_VERSION ::") "" (lib.splitString "\n" (builtins.readFile ./src/browser/about.odin));
    in
      builtins.head (builtins.match ''APP_VERSION :: "([^"]+)".*'' line);

    # The revision the about page shows: g<short hash>, "+" for uncommitted changes (src/tools/wrentool/builder/builder.odin).
    commit = lib.replaceStrings ["-dirty"] ["+"] (self.shortRev or self.dirtyShortRev or "dev");
    commitDate = let
      d = self.lastModifiedDate or "";
    in
      lib.optionalString (d != "") "${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

    desktopItem = pkgs.makeDesktopItem {
      name = "wren";
      desktopName = "Wren";
      genericName = "Web Browser";
      comment = "A browser where WebAssembly runs everything, JavaScript included";
      exec = "wren %U";
      icon = "wren";
      startupNotify = true;
      startupWMClass = "wren";
      categories = ["Network" "WebBrowser"];
      keywords = ["Internet" "WWW" "Browser" "Web" "WebAssembly"];
      # a launcher's right click (the same as src/desktop/identity.odin DESKTOP_ACTIONS)
      actions = {
        new-window = {
          name = "New Window";
          exec = "wren --new-window";
        };
        new-private-window = {
          name = "New Private Window";
          exec = "wren --private";
        };
      };
      # http(s), the links that open in Wren (src/desktop/links.odin), browser.desktop_integration.file_types
      mimeTypes = [
        "x-scheme-handler/http"
        "x-scheme-handler/https"
        "x-scheme-handler/wren-http"
        "x-scheme-handler/wren-https"
        "x-scheme-handler/wren-about"
        "text/html"
        "application/xhtml+xml"
        "image/svg+xml"
        "image/webp"
        "image/avif"
      ];
    };

    # The browser, built from this tree as the release is: wrentool build release.
    wren = pkgs.stdenv.mkDerivation {
      pname = "wren";
      inherit version;
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.difference ./. (lib.fileset.unions (map lib.fileset.maybeMissing [./site ./wpt ./.github ./build]));
      };
      cargoDeps = pkgs.rustPlatform.importCargoLock {lockFile = ./native/Cargo.lock;};

      nativeBuildInputs = [
        odin
        rust.minimal
        pkgs.clang
        pkgs.lld
        pkgs.nasm
        pkgs.pkg-config
        pkgs.unzip
        pkgs.xz
        pkgs.autoPatchelfHook
        pkgs.makeWrapper
        pkgs.copyDesktopItems
      ];
      buildInputs = [pkgs.alsa-lib pkgs.libopus pkgs.fontconfig pkgs.stdenv.cc.cc.lib];
      # the libraries it opens with dlopen go in its RUNPATH; the GPU driver is the system's (/run/opengl-driver)
      runtimeDependencies = runtimeLibs;
      desktopItems = [desktopItem];
      dontStrip = true;
      # Odin links a foreign library as -l:<absolute path> with -L/, which the purity check of the linker wrapper drops
      NIX_ENFORCE_PURITY = 0;

      WREN_SOURCE_COMMIT = commit;
      WREN_SOURCE_DATE = commitDate;

      configurePhase = ''
        runHook preConfigure
        export HOME="$TMPDIR"
        # the crates of native/Cargo.lock, vendored: cargo makes no request
        mkdir -p "$HOME/.cargo"
        cat > "$HOME/.cargo/config.toml" <<EOF
        [source.crates-io]
        replace-with = "vendored-sources"
        [source.vendored-sources]
        directory = "$cargoDeps"
        EOF
        export CARGO_NET_OFFLINE=true
        # wrentool seals wgpu-native into Odin's vendor/: a writable copy of the compiler
        cp -r ${odin}/lib/odin "$TMPDIR/odin"
        chmod -R u+w "$TMPDIR/odin"
        export ODIN_ROOT="$TMPDIR/odin"
        mkdir -p build/tmp build/wasmtime
        cp ${wasmtimeArchive} build/tmp/wasmtime-v${wasmtimeVersion}-x86_64-linux-c-api.tar.xz
        cp ${wgpuArchive} build/tmp/wgpu-linux-x86_64-release.zip
        cp ${wasmtimeLicense} build/wasmtime/LICENSE
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        odin run src/tools/wrentool -collection:wb=src -out:build/wrentool -- build release
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 build/wren "$out/libexec/wren/wren"
        # dialogs (zenity) and links to other programs (xdg-open)
        makeWrapper "$out/libexec/wren/wren" "$out/bin/wren" \
          --prefix PATH : ${lib.makeBinPath [pkgs.zenity pkgs.xdg-utils]}
        # every size the logo is drawn at (wrentool logo): a bar that asks for one at a fractional scale takes it, not a smaller one stretched
        for icon in assets/icons/*.png; do
          size=$(basename "$icon" .png)
          install -Dm644 "$icon" "$out/share/icons/hicolor/''${size}x''${size}/apps/wren.png"
        done
        install -Dm644 -t "$out/share/doc/wren" LICENSE THIRD_PARTY.md
        runHook postInstall
      '';

      meta = {
        description = "A web browser where WebAssembly runs everything, JavaScript included";
        homepage = "https://github.com/sachahjkl/wren";
        license = lib.licenses.unfree; # PolyForm Strict
        platforms = [system];
        mainProgram = "wren";
      };
    };

    preCommit = git-hooks.lib.${system}.run {
      src = ./.;
      package = pkgs.prek;
      hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
      };
    };
  in {
    packages.${system} = {
      inherit wren odin;
      default = wren;
    };

    apps.${system}.default = {
      type = "app";
      program = lib.getExe wren;
      meta.description = "Wren, built from this tree";
    };

    checks.${system} = {
      inherit wren;
      pre-commit = preCommit;
    };

    formatter.${system} = pkgs.alejandra;

    # nix develop: the tools of ./build.sh and of the tests, and the libraries a development build opens at run time.
    devShells.${system}.default = pkgs.mkShell {
      packages =
        [
          odin
          rust.default
        ]
        ++ (with pkgs; [
          clang
          lld
          nasm
          pkg-config
          unzip
          xz
          go
          git
          curl
          xvfb-run
        ])
        ++ preCommit.enabledPackages;
      # (dbus: wrentool build vault links the helper's Secret Service store to libdbus)
      buildInputs = runtimeLibs ++ [pkgs.mesa pkgs.dbus];
      LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
      LD_LIBRARY_PATH = lib.makeLibraryPath (runtimeLibs ++ [pkgs.mesa]);
      # wrentool seals wgpu-native into Odin's vendor/: a writable copy, the store's is read-only
      shellHook =
        ''
          if [ ! -d build/odin-nix ]; then
            mkdir -p build
            cp -r --no-preserve=mode ${odin}/lib/odin build/odin-nix
            chmod +x build/odin-nix/odin
          fi
          export ODIN_ROOT="$PWD/build/odin-nix"
        ''
        + preCommit.shellHook;
    };
  };
}
