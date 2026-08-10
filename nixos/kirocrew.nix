{ ... }:

# Reusable NixOS module: KiroCrew gateway as a pinned OCI container.
# Exported as `nixosModules.kirocrew` from flake.nix.
{
  virtualisation.oci-containers = {
    backend = "docker";
    containers.kirocrew = {
      # Pinned to 0.1.3 (what :stable resolved to on 2026-08-10). For
      # digest-level immutability, use:
      #   ghcr.io/kirodotdev/kirocrew@sha256:ea87f333a80b4c12a614a15358a9c81c2f22aa1d8f6678000ab7a20af1851325
      image = "ghcr.io/kirodotdev/kirocrew:0.1.3";

      # Publish to the GUEST loopback only — reach the dashboard via an SSH
      # tunnel (see nixos/kirocrew.md); never exposed on the network.
      ports = [ "127.0.0.1:5476:5476" ];

      # All persistent state (~/.kiro/crew, kiro-cli creds, agents, skills).
      volumes = [ "kirocrew-home:/home/kirocrew" ];

      # Let KiroCrew's inner user-namespace sandbox work under Docker's seccomp
      # (default profile blocks unshare/clone/mount). Without it, agent command
      # execution fails closed. Path is copied into the nix store (immutable).
      extraOptions = [
        "--security-opt=seccomp=${./seccomp/kirocrew-seccomp.json}"
      ];

      # Optional channel credentials (Slack/Discord/etc.). Create on the host
      # first (mode 600), then uncomment:
      # environmentFiles = [ "/var/lib/kirocrew/.env" ];
    };
  };
}
