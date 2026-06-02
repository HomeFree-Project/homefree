## ─── Radicle OCI image ──────────────────────────────────────────────
##
## Build a single podman-compatible image containing both
## `radicle-node` and `radicle-httpd` from nixpkgs. There is no
## upstream-official Radicle Docker image, and the community gists
## are unmaintained — building from `pkgs.radicle-node` /
## `pkgs.radicle-httpd` pins exactly to the nixpkgs revision the box
## already trusts, with no external registry dependency.
##
## The same image is used by BOTH the radicle-node and radicle-httpd
## podman containers; each container's `cmd` selects which binary to
## run. Smaller surface than two separate images, and the layered
## build deduplicates the shared store paths.
##
## /etc/passwd, /etc/group, /etc/ssl/certs, /bin/sh, /usr/bin/env
## come from dockerTools helpers — radicle binaries depend on TLS
## (HTTPS git clones, peer discovery via DNS) and on git+ssh in
## $PATH (already wrapped in via the nixpkgs package's makeWrapper
## but the unwrapped util binaries are useful for debugging).

{ pkgs, lib }:

pkgs.dockerTools.buildLayeredImage {
  name = "homefree/radicle";
  tag = "local";

  ## Order matters: dockerTools layers contents so later entries can
  ## override earlier ones. Keep the radicle packages first so their
  ## wrapped binaries take precedence over anything in coreutils etc.
  contents = [
    pkgs.radicle-node
    pkgs.radicle-httpd

    ## Runtime deps the radicle binaries expect on PATH or in /etc.
    ## radicle-node's postFixup already wraps in git/openssh/man-db,
    ## but having them in /bin too means interactive debugging works.
    pkgs.gitMinimal
    pkgs.openssh
    pkgs.coreutils
    pkgs.bashInteractive

    ## Standard dockerTools containerization helpers:
    ##   caCertificates  → /etc/ssl/certs/ca-bundle.crt for TLS
    ##   usrBinEnv       → /usr/bin/env for any #!/usr/bin/env shebangs
    ##   binSh           → /bin/sh symlink for shell-out
    ##   fakeNss         → /etc/passwd + /etc/group with a "nobody" and
    ##                     "root" user so glibc's getpwuid() doesn't
    ##                     fail in network-aware code paths
    pkgs.dockerTools.caCertificates
    pkgs.dockerTools.usrBinEnv
    pkgs.dockerTools.binSh
    pkgs.dockerTools.fakeNss
  ];

  ## Pre-create /root and /tmp inside the image so the radicle
  ## binaries have a writeable HOME. RAD_HOME=/root/.radicle below
  ## points at the bind-mounted host data dir at runtime.
  extraCommands = ''
    mkdir -p root tmp
    chmod 1777 tmp
  '';

  config = {
    Env = [
      "PATH=/bin:/usr/bin"
      "HOME=/root"
      "RAD_HOME=/root/.radicle"
      "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
      "GIT_SSL_CAINFO=/etc/ssl/certs/ca-bundle.crt"
    ];
    WorkingDir = "/root";

    ## No Cmd here — each container in default.nix specifies its own
    ## cmd (radicle-node ... vs radicle-httpd ...) so a single image
    ## serves both roles.
  };
}
