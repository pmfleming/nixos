{ lib, ... }:

{
  services.printing.enable = true;

  hardware.printers.ensurePrinters = [
    {
      name = "Epson_ET_2950";
      description = "Epson EcoTank ET-2950";
      # mDNS follows DHCP address changes. The trusted NetworkManager profile
      # needs connection.mdns=1 (resolve only); no Avahi or printer password.
      deviceUri = "ipps://EPSON4C18B4.local:631/ipp/print";
      model = "everywhere";
      ppdOptions = {
        PageSize = "A4";
        "printer-is-shared" = "false";
        "printer-error-policy" = "retry-job";
      };
    }
  ];

  # IPP Everywhere setup queries the actual printer. Never make an offline
  # printer block boot/activation: try asynchronously, bound each attempt,
  # and retry failures. RemainAfterExit (from the upstream module) stops the
  # timer retrying once setup succeeds; ordinary jobs then belong to CUPS.
  systemd.services.ensure-printers = {
    wantedBy = lib.mkForce [ ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig.TimeoutStartSec = "45s";
  };
  systemd.timers.ensure-printers = {
    description = "Retry network printer setup until the printer is reachable";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "30s";
      OnUnitInactiveSec = "2min";
      AccuracySec = "10s";
      Unit = "ensure-printers.service";
    };
  };
}
