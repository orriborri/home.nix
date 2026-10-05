# Shared systemd hardening for KiroCrew host services. Units use it as
#   serviceConfig = hardening // { ... };
# and override only what they must relax, with a comment saying why.
{
  NoNewPrivileges = true;
  ProtectSystem = "strict";
  ProtectHome = true;
  PrivateTmp = true;
  ProtectKernelTunables = true;
  ProtectKernelModules = true;
  ProtectControlGroups = true;
  RestrictSUIDSGID = true;
  RestrictNamespaces = true;
  LockPersonality = true;
  # Block IMDS so the instance role's credentials are out of reach.
  IPAddressDeny = [ "169.254.169.254/32" ];
}
