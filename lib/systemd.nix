rec {
  lowPriority = {
    Nice = 10;
    CPUWeight = 20;
    IOWeight = 20;
  };

  statefulOneshot =
    stateDirectory:
    lowPriority
    // {
      Type = "oneshot";
      StateDirectory = stateDirectory;
      StateDirectoryMode = "0755";
      UMask = "0022";
    };

  nixBuildService = stateDirectory: {
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    environment.NIX_CONFIG = ''
      max-jobs = 1
      cores = 2
    '';
    serviceConfig = statefulOneshot stateDirectory;
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
