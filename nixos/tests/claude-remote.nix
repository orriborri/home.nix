# VM test for the Claude Remote Control sandbox (BACKLOG F1, decision 72).
#
# `box` runs the real kirocrew-claude-egress.nix and kirocrew-claude-remote.nix
# modules. Only two things differ from the deployed unit: its ExecStart is a
# probe script, and the proxy filter lists allowed.test instead of the real
# hosts. Everything the probe checks therefore runs under the unit's real uid,
# hardening, IPAddressDeny/Allow, proxy variables and git config.
#
# Not covered (no internet, no claude.ai login in a VM): `nix-shell -p`, the
# live Remote Control connection through the proxy, the enable/trust prompts,
# and a real GitLab fetch or push over altssh with the pinned host key.
# Those are checked on the box (F1.7).
{ pkgs }:
let
  inherit (pkgs) lib;

  # One certificate for both names; curl trusts it explicitly.
  cert = pkgs.runCommand "claude-remote-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout $out/key.pem -out $out/cert.pem -subj /CN=allowed.test \
      -addext "subjectAltName=DNS:allowed.test,DNS:denied.test"
  '';

  home = "/var/lib/claude-remote";
  curl = "${pkgs.curl}/bin/curl --silent --show-error --max-time 8 --cacert ${cert}/cert.pem";

  # Runs as claude-remote inside the unit. Writes name=value lines; the test
  # asserts on them. No `set -e`: every probe is expected to be able to fail.
  probe = pkgs.writeShellScript "claude-remote-probe" ''
    out=${home}/workspace/probe.out
    : > "$out"
    say() { echo "$1=$2" >> "$out"; }

    say whoami "$(${pkgs.coreutils}/bin/id -un)"
    say proxy_env "$HTTPS_PROXY"

    # allowed host through the proxy (picked up from HTTPS_PROXY)
    say allowed_via_proxy "$(${curl} https://allowed.test/ 2>&1)"

    # host not in the filter, through the proxy: CONNECT is refused
    say denied_via_proxy "$(${curl} --output /dev/null https://denied.test/ 2>&1)"

    # the same allowed host, bypassing the proxy: the IP filter drops it
    ${curl} --noproxy '*' --output /dev/null https://allowed.test/ 2>&1
    say direct_to_web_exit "$?"

    # IMDS, direct and through the proxy
    ${curl} --noproxy '*' --output /dev/null http://169.254.169.254/latest/meta-data/ 2>&1
    say imds_direct_exit "$?"
    # curl ignores uppercase HTTP_PROXY for plain http, so pass it explicitly.
    say imds_via_proxy "$(${curl} --proxy "$HTTP_PROXY" --output /dev/null --write-out '%{http_code}' http://169.254.169.254/latest/meta-data/ 2>&1)"

    # code tree: readable through code-writers (clone works), read-only
    # inside the unit (ProtectSystem=strict).
    cd ${home}/workspace
    ${pkgs.git}/bin/git clone -q /var/lib/code/demo demo 2>&1
    say clone_code_exit "$?"
    ${pkgs.coreutils}/bin/touch /var/lib/code/demo/probe-write 2>/dev/null
    say write_code_exit "$?"

    # 1Password agent relay: ssh-add exits 1 for an agent with no keys and 2
    # when it cannot reach an agent at all.
    say agent_sock "$SSH_AUTH_SOCK"
    ${pkgs.openssh}/bin/ssh-add -l > /dev/null 2>&1
    say agent_exit "$?"

    # GitLab SSH is rewritten to altssh.gitlab.com:443 through the proxy. This
    # test's proxy does not list that host, so CONNECT is refused; the error
    # shows the route git took.
    PATH=${pkgs.openssh}/bin:$PATH ${pkgs.git}/bin/git ls-remote git@gitlab.com:readpeak/demo.git > ${home}/workspace/route.err 2>&1
    say gitlab_route_exit "$?"
    say gitlab_route_msg "$(tr '\n' ' ' < ${home}/workspace/route.err)"
  '';
in
pkgs.testers.runNixOSTest {
  name = "claude-remote-sandbox";

  # The deployed unit names pkgs.claude-code (unfree); the probe replaces its
  # ExecStart, so it is evaluated here but never built or run.
  node.pkgsReadOnly = false;

  nodes = {
    web = _: {
      networking.firewall.allowedTCPPorts = [ 443 ];
      services.nginx = {
        enable = true;
        virtualHosts."allowed.test" = {
          onlySSL = true;
          sslCertificate = "${cert}/cert.pem";
          sslCertificateKey = "${cert}/key.pem";
          locations."/".return = "200 allowed-ok";
        };
        virtualHosts."denied.test" = {
          onlySSL = true;
          sslCertificate = "${cert}/cert.pem";
          sslCertificateKey = "${cert}/key.pem";
          locations."/".return = "200 denied-ok";
        };
      };
    };

    box =
      { nodes, ... }:
      {
        nixpkgs.config.allowUnfreePredicate = pkg: lib.getName pkg == "claude-code";

        imports = [
          ../kirocrew-claude-egress.nix
          ../kirocrew-claude-remote.nix
        ];

        networking.hosts.${nodes.web.networking.primaryIPAddress} = [
          "allowed.test"
          "denied.test"
        ];

        # Only allowed.test is on the proxy allowlist in this test.
        services.tinyproxy.settings.Filter = lib.mkForce (
          pkgs.writeText "test-filter" ''
            ^allowed\.test$
          ''
        );

        # Probe instead of `claude remote-control`; run once, no restart loop.
        systemd.services.claude-remote.serviceConfig = {
          ExecStart = lib.mkForce probe;
          Restart = lib.mkForce "no";
          Type = "oneshot";
        };
      };
  };

  testScript = ''
    start_all()
    web.wait_for_unit("nginx.service")
    web.wait_for_open_port(443)
    box.wait_for_unit("tinyproxy.service")
    box.wait_for_open_port(8888)

    with subtest("unit stays inactive while the credentials file is absent"):
        box.fail("test -e ${home}/.claude/.credentials.json")
        state = box.succeed("systemctl show claude-remote.service -p ActiveState -p ConditionResult")
        assert "ActiveState=inactive" in state, state
        assert "ConditionResult=no" in state, state
        box.succeed("systemctl start claude-remote.service")
        assert "ActiveState=inactive" in box.succeed("systemctl show claude-remote.service -p ActiveState")
        box.fail("test -e ${home}/workspace/probe.out")

    with subtest("after login the probe runs inside the unit"):
        # A repo in the shared code tree, and a stand-in for the operator's
        # forwarded 1Password agent.
        box.succeed(
            "install -d -m 2775 -g code-writers /var/lib/code",
            "${pkgs.git}/bin/git init -q /var/lib/code/demo",
            "${pkgs.git}/bin/git -C /var/lib/code/demo -c user.email=t@t -c user.name=t commit -q --allow-empty -m demo",
            "chgrp -R code-writers /var/lib/code/demo",
            "chmod -R g+rX,o-rwx /var/lib/code/demo",
            "install -d -m 0755 /run/kirocrew-agent",
            "${pkgs.openssh}/bin/ssh-agent -a /run/kirocrew-agent/orre-1p.sock",
        )
        box.wait_for_file("/run/claude-remote/1p-agent.sock")
        box.succeed(
            "install -d -m 0700 -o claude-remote -g claude-remote ${home}/.claude",
            "install -m 0600 -o claude-remote -g claude-remote /dev/null ${home}/.claude/.credentials.json",
            "systemctl start claude-remote.service",
        )
        out = box.succeed("cat ${home}/workspace/probe.out")
        print(out)
        r = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)

    with subtest("identity and proxy environment"):
        assert r["whoami"] == "claude-remote", r
        assert r["proxy_env"] == "http://127.0.0.1:8888", r

    with subtest("allowed host works through the proxy"):
        assert r["allowed_via_proxy"] == "allowed-ok", r

    with subtest("other host is refused by the proxy"):
        assert "CONNECT tunnel failed, response 403" in r["denied_via_proxy"], r

    with subtest("direct connections and IMDS fail"):
        assert r["direct_to_web_exit"] != "0", r
        assert r["imds_direct_exit"] != "0", r
        assert r["imds_via_proxy"] == "403", r

    with subtest("code tree is readable, not writable"):
        assert r["clone_code_exit"] == "0", r
        assert r["write_code_exit"] != "0", r

    with subtest("the forwarded agent is reachable"):
        assert r["agent_sock"] == "/run/claude-remote/1p-agent.sock", r
        assert r["agent_exit"] == "1", r

    with subtest("GitLab SSH goes to altssh.gitlab.com:443 through the proxy"):
        assert r["gitlab_route_exit"] != "0", r
        assert "altssh.gitlab.com" in r["gitlab_route_msg"], r

    with subtest("the relay and its socket go away with the forward"):
        box.succeed("pkill -f 'ssh-agent -a /run/kirocrew-agent/orre-1p.sock'")
        box.succeed("rm -f /run/kirocrew-agent/orre-1p.sock")
        box.wait_until_fails("test -e /run/claude-remote/1p-agent.sock")
  '';
}
