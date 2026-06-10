{ ... }:

{
  users.users.laufan = {
    isNormalUser = true;
    description = "Paul Fleming";
    extraGroups = [
      "audio"
      "input"
      "networkmanager"
      "video"
      "wheel"
    ];
  };
}
