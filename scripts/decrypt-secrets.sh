#!/usr/bin/env bash

sudo -E bash -c 'SOPS_AGE_KEY=$(ssh-to-age -private-key < /etc/ssh/ssh_host_ed25519_key) sops /etc/nixos/secrets/secrets.yaml'

