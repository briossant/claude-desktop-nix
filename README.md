# claude-desktop-nix

Nix flake for the **official Claude Desktop Linux beta** (Chat, Cowork, Claude Code),
repackaged from [Anthropic's apt repository](https://code.claude.com/docs/en/desktop-linux)
for NixOS. Supports `x86_64-linux` and `aarch64-linux`.

## Security model

The binary is Anthropic's own `.deb`, fetched from `downloads.claude.ai` with a
pinned Nix hash. The auto-update pipeline (`scripts/update.sh`) never trusts the
network blindly:

1. the apt signing key is **pinned by fingerprint**
   (`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`, published in Anthropic's docs);
2. the `InRelease` metadata must carry a **valid GPG signature** from that key;
3. each `Packages` index is checked against the SHA256 listed in `InRelease`;
4. only then are the per-arch deb SHA256 hashes copied into `flake.nix`.

Updates arrive as **pull requests** (built and validated in CI first), so every
version bump is reviewed before it can reach a machine that follows this flake.

The packaging (deb extraction, patchelf, Cowork firmware path fixes) is adapted
from [poeck/claude-desktop-nix-flake](https://github.com/poeck/claude-desktop-nix-flake) (MIT).

## Usage

Try it without installing:

```bash
nix run github:briossant/claude-desktop-nix
```

### NixOS module (flake)

```nix
{
  inputs.claude-desktop.url = "github:briossant/claude-desktop-nix";
  inputs.claude-desktop.inputs.nixpkgs.follows = "nixpkgs";

  # in your nixosSystem modules:
  #   inputs.claude-desktop.nixosModules.default
  # then:
  #   programs.claude-desktop.enable = true;
}
```

### Overlay

```nix
nixpkgs.overlays = [ inputs.claude-desktop.overlays.default ];
environment.systemPackages = [ pkgs.claude-desktop ];
```

The package is unfree; enable `allowUnfree` (the flake's own outputs already do).

## Updating

Automatic: the [update workflow](.github/workflows/update.yml) checks Anthropic's
apt repo every 6 hours and opens a PR when a new version is published. The expected
diff is `version` plus the two deb hashes in `flake.nix`, nothing else.

Manual:

```bash
./scripts/update.sh   # needs curl, gnupg, nix, perl
nix build .#claude-desktop
```

## Linux beta limitations (upstream)

No Computer Use, no dictation; Quick Entry global hotkey needs X11 or a
GlobalShortcuts portal on Wayland. See the
[official docs](https://code.claude.com/docs/en/desktop-linux).
