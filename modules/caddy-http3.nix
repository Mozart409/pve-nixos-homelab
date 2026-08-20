# Module to open UDP/443 for Caddy's HTTP/3 (QUIC) support.
# Caddy advertises h3 via alt-svc, but the NixOS firewall drops QUIC
# packets unless UDP 443 is explicitly allowed.
{
  config,
  lib,
  ...
}: {
  networking.firewall.allowedUDPPorts = [443];
}
