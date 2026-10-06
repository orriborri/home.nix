# Daily disk-usage alarm for the headless KiroCrew host.
#
# The fixed 79G root has filled before (see the nix.gc note in
# kirocrew-ec2.nix). This unit fails when the filesystem holding PATH is more
# than THRESHOLD percent full, so the condition appears in
# `systemctl list-units --failed` without any CloudWatch dependency.
{ pkgs, ... }:
let
  check = pkgs.writeShellApplication {
    name = "kirocrew-disk-check";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      path="''${1:-/}"
      threshold="''${2:-85}"
      used="$(df --output=pcent "$path" | tail -n 1 | tr -dc '0-9')"
      if [ "$used" -gt "$threshold" ]; then
        echo "disk usage on $path is $used% (threshold $threshold%)" >&2
        exit 1
      fi
      echo "disk usage on $path is $used% (threshold $threshold%)"
    '';
  };
in
{
  systemd.services.kirocrew-disk-check = {
    description = "Fail when the root filesystem is more than 85% full";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${check}/bin/kirocrew-disk-check / 85";
    };
  };

  systemd.timers.kirocrew-disk-check = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
    };
  };
}
