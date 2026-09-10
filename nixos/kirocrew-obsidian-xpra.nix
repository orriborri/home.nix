{
  config,
  lib,
  pkgs,
  ...
}:

# NixOS module: browser access to the KiroCrew Obsidian vault.
#
# Runs the official Obsidian desktop as a single seamless application inside a
# persistent Xpra session and serves Xpra's built-in HTML5 client on loopback.
# The browser renders the real Obsidian process (full UI, Live Preview, graph,
# Bases, plugin runtime) rather than a reimplementation. Reached through the
# existing SSM/SSH tunnel; no inbound security-group port is opened.
#
# Design (see docs/remote-obsidian-web-options.md):
#   * A dedicated `obsidian-web` system user runs the GUI — NOT kirocrew — so
#     the display process has its own home/state and cannot touch KiroCrew
#     secrets, code, or the gateway's identity.
#   * The service edits /var/lib/vault note content directly. Git/git-crypt
#     (kirocrew-vault-git.nix) remains the ONLY synchronization engine; no
#     second sync engine is added. Obsidian notices external (KiroCrew) file
#     changes on its own.
#   * .git / .gitattributes / .gitignore are made inaccessible to the display
#     process so it cannot invoke Git or weaken git-crypt coverage. Note that
#     git-crypt protects the remote object store, NOT the live plaintext
#     checkout, so this service is a high-value plaintext boundary — hence the
#     loopback bind, TLS + password auth, and feature reduction below.
#
# Access from the operator workstation (through the existing tunnel):
#   ssh -L 14500:127.0.0.1:14500 <kirocrew-ssm-proxy>
#   then open https://127.0.0.1:14500/ in a browser.
let
  vaultDir = "/var/lib/vault";
  stateDir = "/var/lib/obsidian-web";
  bindHost = "127.0.0.1";
  bindPort = 14500;

  # sops-provisioned Xpra password (single line). Provisioned by
  # kirocrew-obsidian-xpra-sops secret below.
  passwordFile = "${stateDir}/secrets/xpra-password";

  # Self-signed TLS material for the loopback listener. Generated on first
  # start into the service's private state (never leaves the host; the tunnel
  # is the transport boundary, TLS is defence in depth on the local socket).
  tlsCert = "${stateDir}/tls/cert.pem";
  tlsKey = "${stateDir}/tls/key.pem";

  # Absolute Obsidian command for Xpra's --start-child. Xpra spawns the child
  # with a minimal environment, so a bare "obsidian" is not resolved on PATH
  # (observed: "[Errno 13] Permission denied: 'obsidian'"). Use the store path.
  # Obsidian is Electron: the Xpra display is headless with no GPU, so disable
  # GPU/sandbox to avoid a black window or a crash on this host.
  obsidianCmd = "${pkgs.obsidian}/bin/obsidian --no-sandbox --disable-gpu";

  # Grant the display user write access to vault NOTE CONTENT only, then make
  # Git internals inaccessible. Mirrors the setfacl cross-user pattern already
  # used for legacy Kiro access in kirocrew-services.nix. Runs as root before
  # the session starts. Idempotent.
  vaultGrant = pkgs.writeShellApplication {
    name = "obsidian-web-vault-grant";
    runtimeInputs = with pkgs; [
      acl
      coreutils
      findutils
    ];
    text = ''
      set -euo pipefail

      if [[ ! -d "${vaultDir}" ]]; then
        echo "Vault checkout absent at ${vaultDir}; run kirocrew-vault-clone first." >&2
        exit 1
      fi

      # Traverse + read/write on the vault tree for the display user. Default
      # ACLs ensure notes and attachments created by KiroCrew afterwards remain
      # editable in the browser.
      setfacl --modify user:obsidian-web:rwX "${vaultDir}"
      setfacl --recursive --modify user:obsidian-web:rwX "${vaultDir}"
      find "${vaultDir}" -type d -not -path "${vaultDir}/.git*" \
        -exec setfacl --modify default:user:obsidian-web:rwX {} +

      # Deny the display process any access to Git internals and the files that
      # govern git-crypt coverage / exclusion. The gateway's Git service stays
      # the sole authority over repository metadata and remote credentials.
      for p in .git .gitattributes .gitignore; do
        if [[ -e "${vaultDir}/$p" ]]; then
          setfacl --recursive --remove user:obsidian-web "${vaultDir}/$p" 2>/dev/null || true
          setfacl --modify user:obsidian-web:--- "${vaultDir}/$p"
        fi
      done
    '';
  };

  # Generate a self-signed cert for the loopback TLS listener if absent.
  tlsInit = pkgs.writeShellApplication {
    name = "obsidian-web-tls-init";
    runtimeInputs = with pkgs; [
      coreutils
      openssl
    ];
    text = ''
      set -euo pipefail
      umask 0077
      mkdir -p "${stateDir}/tls"
      if [[ ! -s "${tlsCert}" || ! -s "${tlsKey}" ]]; then
        openssl req -x509 -newkey rsa:4096 -sha256 -days 825 -nodes \
          -keyout "${tlsKey}" -out "${tlsCert}" \
          -subj "/CN=obsidian-web.localhost" \
          -addext "subjectAltName=IP:127.0.0.1,DNS:localhost"
      fi
    '';
  };

  # Seed Obsidian's vault registry so it opens /var/lib/vault directly instead
  # of showing the vault picker (which, headless with no window manager, leaves
  # no mapped window — the observed "Xpra works but Obsidian shows nothing").
  # obsidian.json lists known vaults: { vaults: { <id>: {path, ts, open} } }.
  # Written once, into the display user's Electron config dir, if absent.
  obsidianInit = pkgs.writeShellApplication {
    name = "obsidian-web-init";
    runtimeInputs = with pkgs; [
      coreutils
      jq
    ];
    text = ''
      set -euo pipefail
      umask 0077
      cfg="${stateDir}/.config/obsidian"
      mkdir -p "$cfg"
      json="$cfg/obsidian.json"

      # Keep the deployment Nix-pinned: Obsidian's built-in updater downloads a
      # newer app .asar into the user-data dir and loads it in preference to the
      # packaged one. Remove any such download every start so the service always
      # runs the nixpkgs-pinned Obsidian. Runs before the early-exit below so it
      # applies on every start, not only first-run.
      rm -f "$cfg"/obsidian-*.asar 2>/dev/null || true

      if [[ -s "$json" ]] && jq -e '.vaults | to_entries[] | select(.value.path == "${vaultDir}")' "$json" >/dev/null 2>&1; then
        echo "Vault already registered in obsidian.json."
        exit 0
      fi
      # Stable 16-hex id derived from the path keeps this idempotent.
      id="$(printf '%s' "${vaultDir}" | sha256sum | cut -c1-16)"
      ts="$(date +%s%3N)"
      jq -n --arg id "$id" --arg path "${vaultDir}" --argjson ts "$ts" \
        '{vaults: {($id): {path: $path, ts: $ts, open: true}}}' > "$json"
      echo "Wrote $json for vault ${vaultDir}."
    '';
  };

  obsidianStart = pkgs.writeShellApplication {
    name = "obsidian-web-start";
    runtimeInputs = with pkgs; [
      coreutils
      xpra
      obsidian
    ];
    text = ''
      set -euo pipefail

      if [[ ! -r "${passwordFile}" ]]; then
        echo "Xpra password not provisioned at ${passwordFile}." >&2
        exit 1
      fi

      # `xpra start` runs a single seamless application in a virtual X display
      # and, with --html=on, serves the bundled HTML5 client on the same TCP
      # socket. Everything below is loopback-only and minimised.
      #
      # --resize-display=yes makes the virtual display track the browser canvas.
      # There is no window manager in the session, so Obsidian's window opens at
      # an Electron-chosen position that is usually off-screen relative to the
      # browser canvas — the "connected but nothing visible" symptom. The
      # background watcher below waits for the Obsidian window and pins it to the
      # display origin at the client canvas size, so it fills the view after any
      # (re)connect regardless of browser size. Uses only the xpra control
      # channel; no window manager needed.
      xpra start \
        --bind-tcp="${bindHost}:${toString bindPort}" \
        --html=on \
        --ssl=on \
        --ssl-cert="${tlsCert}" \
        --ssl-key="${tlsKey}" \
        --tcp-auth="file:filename=${passwordFile}" \
        --daemon=no \
        --resize-display=yes \
        --keyboard-sync=no \
        --exit-with-children=yes \
        --start-child="${obsidianCmd}" \
        --mdns=no \
        --file-transfer=off \
        --open-files=off \
        --open-url=off \
        --printing=no \
        --microphone=off \
        --speaker=off \
        --webcam=no \
        --clipboard-direction=to-server \
        --start-new-commands=no \
        --sharing=no \
        --pulseaudio=no \
        --notifications=no \
        --bell=no \
        --system-tray=no \
        --dbus-launch= \
        --dbus-control=no &
      xpra_pid=$!

      # Window-placement watcher (no WM). While the server runs, find the
      # Obsidian window and pin it to fill the client canvas. The window's own
      # client-geometry=(x, y, w, h) reflects the negotiated browser canvas, so
      # we resize to that. Best-effort: every failure is ignored and retried.
      (
        display=":0"
        while kill -0 "$xpra_pid" 2>/dev/null; do
          info="$(xpra info "$display" 2>/dev/null || true)"
          wid="$(printf '%s\n' "$info" \
            | sed -n "s/^windows\.\([0-9]\+\)\.class-instance=.*[Oo]bsidian.*/\1/p" \
            | head -1)"
          if [[ -n "$wid" ]]; then
            geom="$(printf '%s\n' "$info" \
              | sed -n "s/^windows\.$wid\.client-geometry=(\([0-9]\+\), \([0-9]\+\), \([0-9]\+\), \([0-9]\+\))/\3 \4/p" \
              | head -1)"
            w="''${geom%% *}"
            h="''${geom##* }"
            # Guard against empty/non-numeric before any arithmetic test.
            case "$w$h" in
              "" | *[!0-9]*) w=1280; h=1024 ;;
            esac
            if [[ "$w" -lt 100 || "$h" -lt 100 ]]; then
              w=1280
              h=1024
            fi
            # Only move if not already at the origin filling the canvas, to
            # avoid fighting the user if they later add a WM or move it.
            pos="$(printf '%s\n' "$info" \
              | sed -n "s/^windows\.$wid\.client-geometry=(\([0-9]\+\), \([0-9]\+\),.*/\1 \2/p" | head -1)"
            if [[ "$pos" != "0 0" ]]; then
              xpra control "$display" moveresize "$wid" 0 0 "$w" "$h" >/dev/null 2>&1 || true
            fi
          fi
          sleep 3
        done
      ) &

      wait "$xpra_pid"
    '';
  };
in
{
  # NOTE: official Obsidian is unfree. It is permitted at the system level by
  # the single allowUnfreePredicate in kirocrew.nix (which lists "obsidian").
  # Keep that list authoritative rather than redefining the predicate here — a
  # second definition of this non-mergeable option would conflict.

  # ── Dedicated display identity ─────────────────────────────────────────────
  # Member of vault-readers so it can traverse the vault dir (2750
  # kirocrew vault-readers); the ACL grant above adds write on note content.
  users.groups.obsidian-web = { };
  users.users.obsidian-web = {
    isSystemUser = true;
    group = "obsidian-web";
    extraGroups = [ "vault-readers" ];
    home = stateDir;
    createHome = true;
    shell = pkgs.bashInteractive;
    description = "Obsidian browser (Xpra) display user";
  };

  # Private state: home, XDG dirs, secrets, and TLS material. 0700 so no other
  # service can read the plaintext .obsidian config or the Xpra password.
  systemd.tmpfiles.rules = [
    "d ${stateDir} 0700 obsidian-web obsidian-web -"
    "d ${stateDir}/secrets 0700 obsidian-web obsidian-web -"
    "d ${stateDir}/tls 0700 obsidian-web obsidian-web -"
  ];

  # ── ACL grant (root oneshot, ordered before the session) ───────────────────
  systemd.services.obsidian-web-vault-grant = {
    description = "Grant obsidian-web write access to vault note content (not .git)";
    after = [ "kirocrew-vault-clone.service" ];
    requires = [ "kirocrew-vault-clone.service" ];
    before = [ "obsidian-web.service" ];
    requiredBy = [ "obsidian-web.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${vaultGrant}/bin/obsidian-web-vault-grant";
    };
  };

  # ── Persistent Obsidian-over-Xpra session ──────────────────────────────────
  systemd.services.obsidian-web = {
    description = "Obsidian desktop over Xpra HTML5 (loopback)";
    after = [
      "network.target"
      "kirocrew-vault-clone.service"
      "obsidian-web-vault-grant.service"
    ];
    requires = [
      "kirocrew-vault-clone.service"
      "obsidian-web-vault-grant.service"
    ];
    wantedBy = [ "multi-user.target" ];

    serviceConfig = {
      Type = "simple";
      User = "obsidian-web";
      Group = "obsidian-web";
      UMask = "0077";
      WorkingDirectory = stateDir;

      ExecStartPre = [
        "${tlsInit}/bin/obsidian-web-tls-init"
        "${obsidianInit}/bin/obsidian-web-init"
      ];
      ExecStart = "${obsidianStart}/bin/obsidian-web-start";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = 20;

      # ── systemd hardening (mirrors kirocrew-services.nix) ──────────────
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      # Hide operator/other homes; the service keeps its own StateDirectory.
      ProtectHome = true;
      PrivateTmp = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictSUIDSGID = true;
      # Xpra/Obsidian (Electron) need a user namespace for their own sandbox;
      # keep namespaces available but drop other privilege vectors.
      RestrictNamespaces = false;
      LockPersonality = true;
      MemoryDenyWriteExecute = false; # Electron/Node JIT needs W+X

      # Writable: only note content and the service's private state. Git
      # internals stay read-only even though note content is writable.
      ReadWritePaths = [
        vaultDir
        stateDir
      ];
      ReadOnlyPaths = [
        "-${vaultDir}/.git"
        "-${vaultDir}/.gitattributes"
        "-${vaultDir}/.gitignore"
      ];

      # No IMDS access from the display process.
      IPAddressDeny = [ "169.254.169.254/32" ];
      # Loopback listener + local sockets only.
      RestrictAddressFamilies = [
        "AF_UNIX"
        "AF_INET"
        "AF_INET6"
      ];

      Environment = [
        "HOME=${stateDir}"
        "XDG_CONFIG_HOME=${stateDir}/.config"
        "XDG_CACHE_HOME=${stateDir}/.cache"
        "XDG_DATA_HOME=${stateDir}/.local/share"
        "XDG_STATE_HOME=${stateDir}/.local/state"
        "XDG_RUNTIME_DIR=/run/obsidian-web"
      ];
      RuntimeDirectory = "obsidian-web";
      RuntimeDirectoryMode = "0700";
    };
  };
}
