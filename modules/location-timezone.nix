{ inputs, ... }:
{
  # Implementation, service hardening and tests live with the Rust daemon.
  imports = [ inputs.bar-daemon.nixosModules.location-timezone ];
}
