{
  pkgs,
  kirocrewHome,
  pastaHome,
  pastaDataDir,
  vaultCheckout,
}:

# MCP servers the KiroCrew gateway spawns over stdio: the CFM Tips and Slack
# venv builders, their credential-loading launchers, and the writer for the
# gateway's mcp.json + the kirocrew user's pasta config. Plain function, not
# a NixOS module: kirocrew-services.nix imports it, runs the builders from
# the gateway's ordered ExecStartPre list and kirocrewMcpConfig from the
# kirocrew-mcp-config oneshot.
let
  # CFM Tips MCP server builder — an ExecStartPre of the gateway (runs as the
  # kirocrew user, inside the gateway's sandbox). Clones the pinned aws-samples
  # checkout and builds a self-contained venv the gateway's mcp.json spawns as
  # a stdio MCP server. Everything lives under ${kirocrewHome}/cfm-tips, which
  # is already the gateway unit's single ReadWritePath.
  #
  # Pinned to an immutable SHA (repos.toml carries the same one for the human
  # checkout): this server is handed read-only AWS cost/resource credentials,
  # so it must not silently follow a moving branch.
  #
  # python312, NOT the nixpkgs default python3 (3.14): this AWS-samples repo
  # targets 3.11+ and is not tested against 3.14. Wheels for the deps
  # (boto3/botocore/psutil/mcp) are pulled from PyPI; `mcp` is installed
  # explicitly because the repo's requirements.txt omits it even though the
  # server imports mcp.server/.stdio/.types. gcc + the interpreter's dev
  # headers are on PATH so a dep with no aarch64 wheel (this is a Graviton
  # t4g box) falls back to a source build instead of failing the unit.
  cfmTipsPython = pkgs.python312;
  # Both MCP venvs resolve their dependencies as of this date, so a rebuild
  # cannot pull releases published later. Bump it deliberately, together with
  # the recipe numbers below.
  mcpVenvUploadedPriorTo = "2026-10-06";
  cfmTipsRev = "dcf19f1ed6905bc0c9f556ac28a1d33dd7128a67";
  cfmTipsDir = "${kirocrewHome}/cfm-tips";
  cfmTipsServerBin = "${cfmTipsDir}/.venv/bin/python";
  cfmTipsServerScript = "${cfmTipsDir}/src/mcp_server_with_runbooks.py";
  # Region the cost server queries. Matches the launcher's DEFAULT_REGION
  # (kirocrew_ec2/models.py). Cost Explorer is global, but boto3 still needs a
  # region set; several playbooks (EC2/EBS/RDS describes) are regional.
  cfmTipsAwsRegion = "eu-central-1";
  cfmTipsSourceBuild = pkgs.writeShellApplication {
    name = "cfm-tips-source-build";
    runtimeInputs = with pkgs; [
      coreutils
      git
      cfmTipsPython
      gcc # source-build fallback for any dep without an aarch64 wheel
      gnumake
    ];
    text = ''
      srcRoot="${cfmTipsDir}/src"
      venv="${cfmTipsDir}/.venv"
      export PIP_CACHE_DIR="${cfmTipsDir}/.pip-cache"

      # Public, read-only checkout: ignore user Git URL rewrites so an HTTPS
      # clone can't be redirected to an SSH clone needing credentials.
      export GIT_CONFIG_GLOBAL=/dev/null
      export GIT_CONFIG_NOSYSTEM=1
      export GIT_TERMINAL_PROMPT=0

      mkdir -p "$srcRoot" "$PIP_CACHE_DIR"

      # Clone once, then pin to the exact revision. Fetch the specific SHA so a
      # shallow clone can still check it out (a bare --depth 1 clone only has
      # the branch tip).
      if [ ! -d "$srcRoot/.git" ]; then
        git clone --filter=blob:none https://github.com/aws-samples/sample-cfm-tips-mcp.git "$srcRoot"
      fi
      git -C "$srcRoot" fetch --depth 1 origin "${cfmTipsRev}"
      git -C "$srcRoot" checkout --quiet --detach "${cfmTipsRev}"

      # (Re)build the venv only when the interpreter or the pin changed. A
      # stamp file records the revision the current venv was built against.
      # RECIPE is appended so a change to the build recipe (e.g. the mcp pin
      # below) forces a rebuild even when the source revision is unchanged.
      stamp="$venv/.cfm-tips-rev"
      cfmRecipe=3  # 3: freeze dependencies with --uploaded-prior-to; 2: pin mcp<2 (v1 low-level Server API)
      want="$cfmRecipe:${cfmTipsRev}"
      if [ ! -x "${cfmTipsServerBin}" ] || [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ]; then
        echo "Building CFM Tips venv ($want)..."
        rm -rf "$venv"
        ${cfmTipsPython}/bin/python3 -m venv "$venv"
        "$venv/bin/pip" install --upgrade pip
        # requirements.txt omits mcp (the server imports it) — add it explicitly.
        # Pin mcp<2: the server is written against the v1 low-level Server API
        # (@server.list_tools / @server.call_tool). mcp 2.x removed those
        # decorators, so an unpinned install pulls 2.x and the module fails to
        # import at spawn (AttributeError: 'Server' object has no attribute
        # 'list_tools') — verified broken on the box before this pin.
        "$venv/bin/pip" install --uploaded-prior-to ${mcpVenvUploadedPriorTo} -r "$srcRoot/requirements.txt" "mcp<2"
        echo "$want" > "$stamp"
      fi

      # Smoke test: the module must import (proves boto3 + mcp resolved). Bounded
      # by timeout and non-fatal so a transient import hiccup can't wedge the
      # gateway's startup — the dashboard MCP probe is the real health signal.
      # Smoke test: boto3 must import AND the v1 low-level Server API the server
      # uses must exist (v2 imports fine but lacks the decorators). Bounded and
      # non-fatal — the dashboard MCP probe is the real health signal.
      timeout 30 "$venv/bin/python" -c "import boto3; from mcp.server import Server; s=Server('t'); assert hasattr(s,'list_tools') and hasattr(s,'call_tool')" 2>/dev/null \
        || echo "warning: cfm-tips venv import smoke test failed" >&2
      echo "cfm-tips build complete"
    '';
  };

  # Slack MCP server builder — an ExecStartPre of the gateway (runs as the
  # kirocrew user, inside the gateway's sandbox). Copies the in-repo server
  # module into ${slackMcpDir} and builds a minimal venv whose ONLY non-stdlib
  # dependency is `mcp` (the server talks to the Slack Web API over stdlib
  # urllib). The gateway's mcp.json spawns it over stdio with the shared
  # SLACK_TOKEN in its environment (set by slackMcpLauncher). Everything lives
  # under ${kirocrewHome}, already the gateway unit's ReadWritePath.
  #
  # python312 to match the cfm-tips server (nixpkgs default python3 is 3.14,
  # which the mcp wheels are not yet uniformly built against on aarch64); gcc +
  # make on PATH give a source-build fallback for any dep lacking a Graviton
  # wheel. The server source is pinned by the Nix store path of ./kirocrew-slack-mcp,
  # so a change to server.py changes the store hash and rebuilds the copy.
  slackMcpPython = pkgs.python312;
  slackMcpDir = "${kirocrewHome}/slack-mcp";
  slackMcpSrc = ./kirocrew-slack-mcp;
  slackMcpServerBin = "${slackMcpDir}/.venv/bin/python";
  slackMcpServerScript = "${slackMcpDir}/server.py";
  slackMcpSourceBuild = pkgs.writeShellApplication {
    name = "kirocrew-slack-mcp-build";
    runtimeInputs = with pkgs; [
      coreutils
      slackMcpPython
      gcc
      gnumake
    ];
    text = ''
      dir="${slackMcpDir}"
      venv="$dir/.venv"
      export PIP_CACHE_DIR="$dir/.pip-cache"
      mkdir -p "$dir" "$PIP_CACHE_DIR"

      # Copy the pinned server module out of the Nix store (read-only) into the
      # writable runtime dir. cp -f each start so a server.py change lands.
      cp -f ${slackMcpSrc}/server.py "$dir/server.py"

      # (Re)build the venv when the interpreter, the source hash, OR the build
      # recipe changed. The stamp records "<recipe-version>:<source store path>";
      # bump RECIPE whenever the pip pin or build steps change so an existing
      # venv is rebuilt rather than silently kept.
      RECIPE=3  # 3: freeze dependencies with --uploaded-prior-to; 2: pin mcp<2 (v1 Server API)
      stamp="$venv/.slack-mcp-src"
      want="$RECIPE:${slackMcpSrc}"
      if [ ! -x "${slackMcpServerBin}" ] || [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ]; then
        echo "Building slack-mcp venv ($want)..."
        rm -rf "$venv"
        ${slackMcpPython}/bin/python3 -m venv "$venv"
        "$venv/bin/pip" install --upgrade pip
        # Pin mcp<2: this server is written against the v1 low-level Server API
        # (@server.list_tools / @server.call_tool + stdio_server). mcp 2.x
        # removed those decorators (FastMCP became MCPServer), so an unpinned
        # `pip install mcp` pulls 2.x and the module fails to import at spawn.
        # Verified on the box: mcp 1.30.0 loads the decorators and auth.test
        # succeeds. (The isolated venv means this pin doesn't affect any other
        # server.)
        "$venv/bin/pip" install --uploaded-prior-to ${mcpVenvUploadedPriorTo} "mcp<2"
        echo "$want" > "$stamp"
      fi

      # Smoke test: assert the v1 low-level Server API the module actually uses
      # is present (not just that `mcp` imports — v2 imports too but lacks these
      # decorators). Bounded and non-fatal; the dashboard MCP probe is the real
      # health signal.
      timeout 30 "$venv/bin/python" -c "from mcp.server import Server; from mcp.server.stdio import stdio_server; s=Server('t'); assert hasattr(s,'list_tools') and hasattr(s,'call_tool')" 2>/dev/null \
        || echo "warning: slack-mcp venv v1-API smoke test failed" >&2
      echo "slack-mcp build complete"
    '';
  };

  # Launchers for the MCP servers that need credentials. Each reads its secrets
  # from the sops-provisioned files when the gateway spawns it, so the gateway
  # process holds no secrets in its environment and the agent shells it spawns
  # do not inherit them. A missing file is non-fatal: the server starts without
  # credentials and its tools error until the secret is provisioned.
  cfmTipsMcpLauncher = pkgs.writeShellScript "kirocrew-cfm-tips-mcp" ''
    secrets=${kirocrewHome}/secrets
    if [ -r "$secrets/cfm-tips-aws-access-key-id" ] && [ -r "$secrets/cfm-tips-aws-secret-access-key" ]; then
      AWS_ACCESS_KEY_ID="$(< "$secrets/cfm-tips-aws-access-key-id")"
      AWS_SECRET_ACCESS_KEY="$(< "$secrets/cfm-tips-aws-secret-access-key")"
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    fi
    exec ${cfmTipsServerBin} ${cfmTipsServerScript} "$@"
  '';
  slackMcpLauncher = pkgs.writeShellScript "kirocrew-slack-mcp" ''
    token=${kirocrewHome}/secrets/slack-token
    if [ -r "$token" ]; then
      SLACK_TOKEN="$(< "$token")"
      export SLACK_TOKEN
    fi
    exec ${slackMcpServerBin} ${slackMcpServerScript} "$@"
  '';

  # MCP wiring for the gateway. Writes the gateway's mcp.json (which spawns the
  # kb-mcp stdio server built by the pasta-daemon) and the kirocrew user's
  # pasta config so kb-mcp resolves the SAME data_dir as the indexer. Runs as
  # kirocrew so file ownership matches the gateway. Idempotent: overwrites both
  # files each start so config drift can't accumulate.
  kirocrewMcpConfig = pkgs.writeShellApplication {
    name = "kirocrew-mcp-config";
    runtimeInputs = with pkgs; [ coreutils ];
    text = ''
      crewDir="${kirocrewHome}/.kiro/crew"
      pastaCfgDir="${kirocrewHome}/.pasta"
      mkdir -p "$crewDir" "$pastaCfgDir"

      # kb-mcp resolves [kb] data_dir from $HOME/.pasta/config.toml. The gateway
      # spawns kb-mcp with HOME=${kirocrewHome}, so this file must point at the
      # shared store the pasta indexer writes.
      cat > "$pastaCfgDir/config.toml" <<EOF
      [general]
      vault_path = "${vaultCheckout}"
      log_level = "info"

      [kb]
      data_dir = "${pastaDataDir}"
      EOF


      # Gateway MCP registry. kb-evidence spawns the locally-built kb-mcp stdio
      # server (linked into ${pastaHome}/bin by the pasta-daemon build step).
      # cfm-tips spawns the aws-samples cost-optimization server from the venv
      # built by cfm-tips-source-build (an ExecStartPre above). cfm-tips and
      # slack start through launchers that load their credentials from the
      # sops files (cfmTipsMcpLauncher, slackMcpLauncher above).
      cat > "$crewDir/mcp.json" <<EOF
      {
        "mcpServers": {
          "kb-evidence": {
            "command": "${pastaHome}/bin/kb-mcp",
            "args": [],
            "env": {
              "HOME": "${kirocrewHome}",
              "RUST_LOG": "error"
            },
            "disabled": false
          },
          "cfm-tips": {
            "command": "${cfmTipsMcpLauncher}",
            "args": [],
            "env": {
              "HOME": "${kirocrewHome}",
              "AWS_REGION": "${cfmTipsAwsRegion}",
              "AWS_DEFAULT_REGION": "${cfmTipsAwsRegion}"
            },
            "disabled": false
          },
          "slack": {
            "command": "${slackMcpLauncher}",
            "args": [],
            "env": {
              "HOME": "${kirocrewHome}"
            },
            "disabled": false
          }
        }
      }
      EOF
      echo "wrote $crewDir/mcp.json and $pastaCfgDir/config.toml"
    '';
  };
in
{
  inherit cfmTipsSourceBuild slackMcpSourceBuild kirocrewMcpConfig;
}
