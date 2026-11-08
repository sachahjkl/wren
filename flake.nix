{
  description = "Wren, a browser written from scratch in Odin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = p: lib.getName p == "wren";   # (PolyForm Strict: this flake's own package only)
      };

      # What the executable links, and what it loads with dlopen when it opens a window or a GPU device (docs/portability.md).
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
      ];

      # The compiler this tree is written for (odin.version; the same release and SHA-256 as .github/workflows/ci.yml).
      odinTag = "dev-2026-11a";
      odin = pkgs.stdenv.mkDerivation {
        pname = "odin";
        version = odinTag;
        src = pkgs.fetchurl {
          url = "https://github.com/odin-lang/Odin/releases/download/${odinTag}/odin-linux-amd64-${odinTag}.tar.gz";
          sha256 = "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618";
        };
        nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper ];
        buildInputs = [ pkgs.stdenv.cc.cc.lib pkgs.zlib pkgs.libxml2 pkgs.zstd pkgs.ncurses ];
        dontBuild = true;
        dontStrip = true;
        sourceRoot = ".";
        autoPatchelfIgnoreMissingDeps = true;   # (the libraries of vendor/ that Wren doesn't use: raylib wants X11, and so on)
        installPhase = ''
          runHook preInstall
          root="$(dirname "$(find . -maxdepth 3 -name odin -type f | head -1)")"
          mkdir -p "$out/lib/odin" "$out/bin"
          cp -r "$root"/. "$out/lib/odin/"
          makeWrapper "$out/lib/odin/odin" "$out/bin/odin" \
            --set-default ODIN_ROOT "$out/lib/odin" \
            --prefix PATH : ${lib.makeBinPath [ pkgs.clang pkgs.lld ]}
          runHook postInstall
        '';
      };

      # The latest Linux release, as published (wrentool package). The release workflow writes nix/release.json from the
      # release's SHA256SUMS-linux.txt.
      release = lib.importJSON ./nix/release.json;
      # The menu entry, as Setup writes it (src/desktop/desktop_entry.odin): http(s), the links that open in Wren
      # (src/desktop/links.odin) and the file types of browser.desktop_integration.file_types.
      desktopItem = pkgs.makeDesktopItem {
        name = "wren";
        desktopName = "Wren";
        genericName = "Web Browser";
        comment = "A browser where WebAssembly runs everything, JavaScript included";
        exec = "wren %U";
        icon = "wren";
        startupNotify = true;
        categories = [ "Network" "WebBrowser" ];
        keywords = [ "Internet" "WWW" "Browser" "Web" "WebAssembly" ];
        mimeTypes = [
          "x-scheme-handler/http" "x-scheme-handler/https"
          "x-scheme-handler/wren-http" "x-scheme-handler/wren-https" "x-scheme-handler/wren-about"
          "text/html" "application/xhtml+xml" "image/svg+xml" "image/webp" "image/avif"
        ];
      };
      wren = pkgs.stdenv.mkDerivation {
        pname = "wren";
        inherit (release) version;
        src = pkgs.fetchurl {
          url = "https://github.com/sachahjkl/wren/releases/download/v${release.version}/wren-${release.version}-linux-x64.tar.gz";
          inherit (release) sha256;
        };
        nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.makeWrapper pkgs.copyDesktopItems ];
        buildInputs = runtimeLibs ++ [ pkgs.stdenv.cc.cc.lib ];
        desktopItems = [ desktopItem ];
        dontBuild = true;
        dontStrip = true;
        installPhase = ''
          runHook preInstall
          install -Dm755 wren "$out/lib/wren/wren"
          install -Dm644 README.txt "$out/share/doc/wren/README.txt"
          for size in 16 32 64 256; do
            install -Dm644 ${./assets}/logo_$size.png "$out/share/icons/hicolor/''${size}x''${size}/apps/wren.png"
          done
          # the window and GPU libraries are loaded with dlopen: autoPatchelf can't see them
          makeWrapper "$out/lib/wren/wren" "$out/bin/wren" \
            --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath runtimeLibs} \
            --prefix PATH : ${lib.makeBinPath [ pkgs.zenity pkgs.xdg-utils ]}
          runHook postInstall
        '';
        meta = {
          description = "A browser where WebAssembly runs everything, JavaScript included";
          homepage = "https://github.com/sachahjkl/wren";
          platforms = [ system ];
          mainProgram = "wren";
          sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          license = lib.licenses.unfree;   # PolyForm Strict
        };
      };
    in
    {
      packages.${system} = {
        inherit wren odin;
        default = wren;
      };

      apps.${system}.default = {
        type = "app";
        program = lib.getExe wren;
      };

      # `nix develop`, then `./build.sh deps` and `./build.sh` (docs/portability.md). The Rust toolchain is pinned by the scripts:
      # `rustup toolchain install 1.99.1 --profile minimal` once. build/js/wren_js.wasm comes from a Windows build or the release workflow.
      devShells.${system}.default = pkgs.mkShell {
        packages = (with pkgs; [
          clang
          lld
          nasm
          pkg-config
          cmake
          gnumake
          rustup
          go
          git
          curl
          unzip
          xvfb-run
        ]) ++ [ odin ];
        buildInputs = runtimeLibs ++ [ pkgs.mesa ];
        LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
        LD_LIBRARY_PATH = lib.makeLibraryPath (runtimeLibs ++ [ pkgs.mesa ]);
        RUSTUP_TOOLCHAIN = "1.99.1";
        # wrentool fetch wgpu puts its library in Odin's vendor/: a writable copy, the store's is read-only
        shellHook = ''
          if [ ! -d build/odin-nix ]; then
            mkdir -p build
            cp -r --no-preserve=mode ${odin}/lib/odin build/odin-nix
          fi
          export ODIN_ROOT="$PWD/build/odin-nix"
        '';
      };
    };
}
