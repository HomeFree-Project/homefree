{ config, pkgs, ... }:
let
  lan-address = config.homefree.network.lan-address;
in
{
  services.mysql = {
    enable = true;
    package = pkgs.mariadb;
    configFile = pkgs.writeText "mysql.cnf" ''
      [mysqld]
      datadir = /var/lib/mysql
      bind-address = 127.0.0.1
      bind-address = ${lan-address}
      port = 3306
    '';
  };
}
