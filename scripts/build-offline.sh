#!/usr/bin/env bash

set -e

SOURCE=${BASH_SOURCE[0]}
while [ -L "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )
  SOURCE=$(readlink "$SOURCE")
  [[ $SOURCE != /* ]] && SOURCE=$DIR/$SOURCE # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR=$( cd -P "$( dirname "$SOURCE" )" >/dev/null 2>&1 && pwd )

HOSTNAME=$(hostname)

if ! command -v nix &> /dev/null
then
    echo "nix could not be found. If it is installed, you may need to log out and log in again for it to be in your path."
    exit 1
fi
## Use relative path for HomeFree source
## This doesn't work unless the flake is locked or the homefree folder is all check in to git
## See issue: https://github.com/NixOS/nix/issues/11181
nix flake update homefree
nix flake lock --override-input homefree "${DIR}/homefree"
export NIX_REMOTE=daemon
ulimit -n 4096
sudo nixos-rebuild switch --offline --flake .#${HOSTNAME} -L
