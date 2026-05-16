{ ... }:
{
  homefree = {
    system = {
      adminUsername = "@@username@@";
      timeZone = "@@timezone";
    };

    ## @TODO: Rename? e.g. user-services; optional-services? web-services?  There are other services besides these.
    services = {
      adguard = {
        enable = true;
      };
    };
  };
}
