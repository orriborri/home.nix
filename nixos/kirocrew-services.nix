{ lib, pkgs, ... }:

# NixOS module: what the KiroCrew host needs besides the gateway unit itself
# (kirocrew-gateway.nix): the operator-facing `kirocrew` wrapper and the
# tmpfiles rules for the socket-bridge and pasta directories. pasta.nix,
# kirocrew-mcp-servers.nix and kirocrew-1p-relay.nix hold the rest of what
# used to live here.
let
  kirocrewHome = "/var/lib/kirocrew";
  pastaHome = "/var/lib/pasta";

  # The kb store (LanceDB + Tantivy index). Written by the pasta indexer and
  # read by the kb-mcp server the gateway spawns. Group-readable via the
  # shared vault-readers group (see kirocrew-security.nix + tmpfiles below).
  pastaDataDir = "${pastaHome}/data";

  kirocrewLibraryPath = lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
  ];
  # Absolute path to the source-built gateway under the kirocrew user's home.
  kirocrewSourceBin = "${kirocrewHome}/.local/share/kirocrew-source/current/.venv/bin/kirocrew";

  # Operator-facing `kirocrew` command.
  #
  # On this host the gateway runs as the dedicated kirocrew user and ALL of its
  # state — config, sessions, sockets — lives under ${kirocrewHome}. Nothing
  # installs the CLI for the operator (the Home Manager user service and its
  # source-update timer are workstation-only), so administering the box meant
  # becoming the kirocrew user by hand first.
  #
  # Merely putting the built binary on the operator's PATH would be worse than
  # missing: the CLI resolves its state from $HOME/$KIROCREW_HOME, so as `orre`
  # it would silently address a DIFFERENT, empty instance — `config get` would
  # read a config the gateway never sees. This wrapper re-enters as the kirocrew
  # user with the gateway's own environment, so it always reports the live
  # instance.
  #
  # Not a privilege grant: `orre` already holds passwordless sudo through wheel
  # (kirocrew-security.nix), while the kirocrew user has no sudo at all. This
  # only removes the `sudo -u kirocrew env HOME=... KIROCREW_HOME=...`
  # incantation. The setuid sudo from the system wrapper dir is required —
  # pkgs.sudo in a store path is not setuid.
  kirocrewCli = pkgs.writeShellApplication {
    name = "kirocrew";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      bin=${kirocrewSourceBin}
      if [ ! -x "$bin" ]; then
        echo "kirocrew is not built yet ($bin is missing)." >&2
        echo "The kirocrew-gateway service builds it on start; check:" >&2
        echo "  systemctl status kirocrew-gateway" >&2
        exit 1
      fi

      # The kirocrew user already IS the right identity with the right HOME, and
      # it has no sudo — so it must exec directly. root can too. Only the
      # operator needs to cross the identity boundary.
      case "$(id -un)" in
        kirocrew | root) exec "$bin" "$@" ;;
      esac

      # Set the environment with env(1) rather than `sudo VAR=val`: sudo only
      # accepts command-line variable assignments when sudoers grants SETENV,
      # so env keeps this working under the default env_reset policy.
      exec /run/wrappers/bin/sudo -u kirocrew -- env \
        HOME=${kirocrewHome} \
        KIROCREW_HOME=${kirocrewHome}/.kiro/crew \
        LD_LIBRARY_PATH=${kirocrewLibraryPath} \
        PATH=${kirocrewHome}/bin:${kirocrewHome}/.local/bin:/run/current-system/sw/bin \
        "$bin" "$@"
    '';
  };

in
{
  # Operator `kirocrew` command (wrapper above). Lands at
  # /run/current-system/sw/bin/kirocrew. It does not shadow the kirocrew user's
  # own CLI: that user's PATH puts ${kirocrewHome}/.local/bin first, and the
  # wrapper execs the real binary directly for kirocrew and root anyway.
  environment.systemPackages = [ kirocrewCli ];

  # ── Ensure kirocrew socket-bridge directories ──────────────────────────────
  # /run/kirocrew-agent: where sshd binds the operator's forwarded socket
  #   (must be writable by orre so the -R forward can create the socket).
  # /run/kirocrew: where the relay (kirocrew-1p-relay.nix) exposes the socket to the gateway.
  systemd.tmpfiles.rules = [
    "d /run/kirocrew-agent 0750 orre kirocrew -"
    "d /run/kirocrew 0750 kirocrew kirocrew -"
    # Pasta build/runtime dirs (pasta user owns its home tree). The build
    # script also mkdir -p's these, but declaring them guarantees ownership
    # and that PASTA_DATA_DIR exists before the daemon starts. The data dir is
    # group-owned by vault-readers and setgid (2750) so the index files the
    # pasta user writes are readable by the kirocrew gateway (which spawns
    # kb-mcp), and new files inherit the group.
    "d ${pastaHome}/bin 0755 pasta pasta -"
    "d ${pastaDataDir} 2750 pasta vault-readers -"
    # KiroCrew skill files (synced from managed skill checkouts by
    # kirocrew-skill-sync.service in kirocrew-code.nix).
    "d ${kirocrewHome}/.kiro/crew/skills 0755 kirocrew kirocrew -"
  ];
}
