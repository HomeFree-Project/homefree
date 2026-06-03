{ pkgs, ... }:
{
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    ## TCP listener is bound only to loopback. All HomeFree consumers
    ## (snipe-it, mediawiki) reach MariaDB via the unix socket at
    ## /run/mysqld/mysqld.sock — they bind-mount /run/mysqld into
    ## their containers. The previous lan-address bind was unused in
    ## practice (containers connect from the podman bridge, not the
    ## LAN subnet) and exposed the cluster to any other host on the
    ## LAN that happened to learn the address.
    ##
    ## MariaDB's bind-address directive is single-value — the
    ## last-listed value wins — so the previous config (two lines,
    ## 127.0.0.1 then lan-address) was effectively only listening on
    ## the LAN address. Dropping the LAN line restores loopback
    ## listening for any future host-side admin work and removes the
    ## off-host attack surface.
    configFile = pkgs.writeText "mysql.cnf" ''
      [mysqld]
      datadir = /var/lib/mysql
      bind-address = 127.0.0.1
      port = 3306
    '';
  };
}
