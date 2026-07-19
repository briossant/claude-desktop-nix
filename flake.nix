{
  description = "Official Claude Desktop Linux beta, repackaged for NixOS from Anthropic's apt repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    let
      # ------------------------------------------------------------------ #
      #  Per-system packages                                                #
      # ------------------------------------------------------------------ #
      perSystem = flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };

          # -------------------------------------------------------------- #
          #  Version & deb hashes — managed by scripts/update.sh.           #
          #  The hashes are copied from Anthropic's apt metadata after      #
          #  verifying its GPG signature (see the update script).           #
          #  Do not edit the marker comments: the updater targets them.     #
          # -------------------------------------------------------------- #
          version = "1.22209.3"; # claude-desktop-version
          debSrcs = {
            x86_64-linux = {
              debArch = "amd64";
              hash = "sha256-1Cf0askjPbxNikQaYC8J91C4pfBdH8egAoXXps4HZVw="; # deb-hash-amd64
            };
            aarch64-linux = {
              debArch = "arm64";
              hash = "sha256-Vcy0eLItcbRuZpWC565Nb0T8bf8LPVFakWMEnatANLI="; # deb-hash-arm64
            };
          };
          debSrc = debSrcs.${system};

          # Cowork sandbox VMs boot with QEMU; the app hardcodes Debian
          # firmware/virtiofsd paths that we patch to their Nix equivalents.
          firmwareCodePath =
            if pkgs.stdenv.hostPlatform.isAarch64 then
              "${pkgs.qemu}/share/qemu/edk2-aarch64-code.fd"
            else
              "${pkgs.OVMF.fd}/FV/OVMF_CODE.fd";

          runtimeLibs = with pkgs; [
            alsa-lib
            at-spi2-core
            cairo
            cups
            dbus
            expat
            fontconfig
            freetype
            gdk-pixbuf
            glib
            gtk3
            libayatana-appindicator
            libcap_ng
            libdrm
            libgbm
            libGL
            libnotify
            libpulseaudio
            libsecret
            libseccomp
            libuuid
            libva
            libxkbcommon
            mesa
            nspr
            nss
            pango
            stdenv.cc.cc.lib
            systemd
            vulkan-loader
            wayland
            libx11
            libxscrnsaver
            libxcomposite
            libxcursor
            libxdamage
            libxext
            libxfixes
            libxi
            libxrandr
            libxrender
            libxtst
            libxcb
          ];

          runtimeBins = with pkgs; [
            glib
            qemu
            trash-cli
            xdg-utils
          ];

          # -------------------------------------------------------------- #
          #  Claude Desktop — packaging adapted from                        #
          #  github.com/poeck/claude-desktop-nix-flake (MIT)                #
          # -------------------------------------------------------------- #
          claude-desktop = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "claude-desktop";
            inherit version;

            src = pkgs.fetchurl {
              url = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop/claude-desktop_${finalAttrs.version}_${debSrc.debArch}.deb";
              inherit (debSrc) hash;
            };

            nativeBuildInputs = with pkgs; [
              dpkg
              asar
              autoPatchelfHook
              makeWrapper
              perl
              wrapGAppsHook3
            ];

            buildInputs = runtimeLibs;

            dontConfigure = true;
            dontBuild = true;
            dontStrip = true;
            dontWrapGApps = true;

            unpackPhase = ''
              runHook preUnpack
              dpkg-deb --fsys-tarfile "$src" | tar --extract --file - --no-same-permissions
              runHook postUnpack
            '';

            installPhase = ''
              runHook preInstall

              mkdir -p "$out/lib" "$out/share"
              cp -a usr/lib/claude-desktop "$out/lib/"
              cp -a usr/share/applications usr/share/icons usr/share/doc "$out/share/"

              substituteInPlace "$out"/share/applications/*.desktop \
                --replace-fail "Exec=claude-desktop" "Exec=$out/bin/claude-desktop"

              asarRoot="$(mktemp -d)"
              asar extract "$out/lib/claude-desktop/resources/app.asar" "$asarRoot"

              # The firmware/virtiofsd path table lives in a content-hashed
              # chunk file, not always .vite/build/index.js, so locate it by
              # content instead of by a fixed name.
              firmwarePatchTarget="$(grep -rlF 'AAVMF_CODE' "$asarRoot/.vite/build")"
              if [ "$(printf '%s\n' "$firmwarePatchTarget" | wc -l)" != 1 ]; then
                echo "expected exactly one file containing AAVMF_CODE, got:" >&2
                printf '%s\n' "$firmwarePatchTarget" >&2
                exit 1
              fi

              FIRMWARE_CODE_PATH="${firmwareCodePath}" \
              VIRTIOFSD_PATH="$out/lib/claude-desktop/resources/virtiofsd" \
              perl -0pi -e '
                s{([A-Za-z0-9_\$]+)=process\.arch==="arm64"\?\["/usr/share/AAVMF/AAVMF_CODE\.fd"\]:\["/usr/share/OVMF/OVMF_CODE_4M\.fd","/usr/share/OVMF/OVMF_CODE\.fd"\]}{$1=["$ENV{FIRMWARE_CODE_PATH}"]} or die "failed to patch firmware path\n";
                s{([A-Za-z0-9_\$]+)=\["/usr/libexec/virtiofsd","/usr/bin/virtiofsd"\]}{$1=["$ENV{VIRTIOFSD_PATH}"]} or die "failed to patch virtiofsd path\n";
                s{return ([A-Za-z0-9_\$]+)\.replace\("OVMF_CODE","OVMF_VARS"\)\.replace\("AAVMF_CODE","AAVMF_VARS"\)}{return $1.replace("OVMF_CODE","OVMF_VARS").replace("AAVMF_CODE","AAVMF_VARS").replace("edk2-aarch64-code.fd","edk2-arm-vars.fd")} or die "failed to patch firmware vars path\n";
              ' "$firmwarePatchTarget"

              rm "$out/lib/claude-desktop/resources/app.asar"
              asar pack --unpack "*.node" "$asarRoot" "$out/lib/claude-desktop/resources/app.asar"

              runHook postInstall
            '';

            preFixup = ''
              gappsWrapperArgs+=(
                --prefix PATH : ${pkgs.lib.makeBinPath runtimeBins}
                --prefix LD_LIBRARY_PATH : ${pkgs.lib.makeLibraryPath runtimeLibs}
                --set-default ELECTRON_OZONE_PLATFORM_HINT auto
              )
            '';

            postFixup = ''
              makeWrapper "$out/lib/claude-desktop/claude-desktop" "$out/bin/claude-desktop" \
                "''${gappsWrapperArgs[@]}"
            '';

            meta = with pkgs.lib; {
              description = "Official Claude Desktop Linux beta";
              homepage = "https://claude.ai";
              changelog = "https://code.claude.com/docs/en/desktop-linux";
              license = licenses.unfree;
              mainProgram = "claude-desktop";
              platforms = [ "x86_64-linux" "aarch64-linux" ];
              sourceProvenance = [ sourceTypes.binaryNativeCode ];
            };
          });

        in
        {
          packages = {
            inherit claude-desktop;
            default = claude-desktop;
          };

          apps = rec {
            claude-desktop = {
              type = "app";
              program = "${self.packages.${system}.claude-desktop}/bin/claude-desktop";
            };
            default = claude-desktop;
          };
        }
      );

    in
    perSystem // {

      # ------------------------------------------------------------------ #
      #  Overlay — drop claude-desktop into pkgs                            #
      # ------------------------------------------------------------------ #
      overlays.default = final: _prev: {
        claude-desktop = self.packages.${final.system}.claude-desktop;
      };

      # ------------------------------------------------------------------ #
      #  NixOS module                                                       #
      # ------------------------------------------------------------------ #
      nixosModules.default = { config, lib, pkgs, ... }:
        let cfg = config.programs.claude-desktop;
        in {
          options.programs.claude-desktop = {
            enable = lib.mkEnableOption "Claude Desktop (official Linux beta)";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.claude-desktop;
              defaultText = lib.literalExpression "claude-desktop from this flake";
              description = "Claude Desktop package to install.";
            };
          };

          config = lib.mkIf cfg.enable {
            environment.systemPackages = [ cfg.package ];

            # Quick Entry and file pickers go through the XDG portals
            xdg.portal.enable = lib.mkDefault true;
            xdg.portal.extraPortals = lib.mkDefault [ pkgs.xdg-desktop-portal-gtk ];
          };
        };

    };
}
