rec {
  lowPriority = {
    Nice = 10;
    CPUWeight = 20;
    IOWeight = 20;
  };

  nixBuildService = serviceConfig: {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.NIX_CONFIG = ''
      max-jobs = 1
      cores = 2
    '';
    serviceConfig =
      lowPriority
      // {
        Type = "oneshot";
        StateDirectoryMode = "0755";
        UMask = "0022";
        TimeoutStopSec = "3min";
        KillMode = "mixed";
      }
      // serviceConfig;
  };

  timer = description: timerConfig: {
    inherit description;
    wantedBy = [ "timers.target" ];
    timerConfig = {
      Persistent = true;
    }
    // timerConfig;
  };
}
