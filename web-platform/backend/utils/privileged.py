#!/usr/bin/env python3
"""
Privileged command execution helper using pkexec.
Wraps commands that require root privileges with pkexec.
"""

import subprocess
import os
from typing import List, Union, Optional

# Commands that require privilege escalation
PRIVILEGED_COMMANDS = {
    'umount', 'wipefs', 'parted', 'mkfs.vfat', 'mkfs.btrfs',
    'mkswap', 'swapon', 'mount', 'btrfs', 'nixos-generate-config',
    'nixos-install', 'nixos-enter', 'cat', 'chown', 'chmod', 'mkdir', 'ln', 'git'
}

PKEXEC_WRAPPER = "/etc/homefree-installer/pkexec-wrapper.sh"
# NixOS setuid wrapper path
PKEXEC_BIN = "/run/wrappers/bin/pkexec"


def needs_privilege(command: Union[str, List[str]]) -> bool:
    """
    Check if a command needs privilege escalation.

    Args:
        command: Command string or list of command arguments

    Returns:
        True if command needs pkexec, False otherwise
    """
    if isinstance(command, str):
        # Extract first word from shell command
        cmd_name = command.strip().split()[0] if command.strip() else ""
        cmd_args = command
    else:
        # Get first element from list
        cmd_name = command[0] if command else ""
        cmd_args = ' '.join(command) if command else ""

    # Get base command name without path
    cmd_base = os.path.basename(cmd_name)

    # Check if command operates on /mnt (installation target)
    if '/mnt' in cmd_args:
        return True

    return cmd_base in PRIVILEGED_COMMANDS


def wrap_command(command: Union[str, List[str]], shell: bool = False) -> Union[str, List[str]]:
    """
    Wrap a command with pkexec if it requires privileges.

    Args:
        command: Command to wrap (string or list)
        shell: Whether this is a shell command

    Returns:
        Wrapped command in the same format as input
    """
    if not needs_privilege(command):
        return command

    if shell and isinstance(command, str):
        # For shell commands, we need to wrap the entire command
        return f"{PKEXEC_BIN} {PKEXEC_WRAPPER} bash -c '{command}'"
    elif isinstance(command, list):
        # For list commands, prepend pkexec wrapper
        return [PKEXEC_BIN, PKEXEC_WRAPPER] + command
    else:
        # String command not for shell
        if isinstance(command, str):
            parts = command.split()
            return [PKEXEC_BIN, PKEXEC_WRAPPER] + parts
        return command


def run_privileged(command: List[str], **kwargs) -> subprocess.CompletedProcess:
    """
    Run a command with privilege escalation if needed.
    Wrapper around subprocess.run that automatically adds pkexec.

    Args:
        command: Command to run as list of arguments
        **kwargs: Additional arguments to pass to subprocess.run

    Returns:
        subprocess.CompletedProcess result
    """
    wrapped_cmd = wrap_command(command, shell=kwargs.get('shell', False))
    return subprocess.run(wrapped_cmd, **kwargs)


def check_output_privileged(command: List[str], **kwargs) -> bytes:
    """
    Run a command with privilege escalation and return output.
    Wrapper around subprocess.check_output that automatically adds pkexec.

    Args:
        command: Command to run as list of arguments
        **kwargs: Additional arguments to pass to subprocess.check_output

    Returns:
        Command output as bytes
    """
    wrapped_cmd = wrap_command(command, shell=kwargs.get('shell', False))
    return subprocess.check_output(wrapped_cmd, **kwargs)


def popen_privileged(command: List[str], **kwargs) -> subprocess.Popen:
    """
    Start a process with privilege escalation if needed.
    Wrapper around subprocess.Popen that automatically adds pkexec.

    Args:
        command: Command to run as list of arguments
        **kwargs: Additional arguments to pass to subprocess.Popen

    Returns:
        subprocess.Popen process object
    """
    wrapped_cmd = wrap_command(command, shell=kwargs.get('shell', False))
    return subprocess.Popen(wrapped_cmd, **kwargs)


def write_file_privileged(file_path: str, content: str) -> None:
    """
    Write a file with privilege escalation if needed.

    Args:
        file_path: Path to file to write
        content: Content to write to file
    """
    # Check if file path requires privileges (e.g., /mnt/*)
    if file_path.startswith('/mnt/'):
        # Use pkexec wrapper to write file as root
        proc = subprocess.Popen(
            [PKEXEC_BIN, PKEXEC_WRAPPER, "write-file", file_path],
            stdin=subprocess.PIPE,
            text=True
        )
        proc.communicate(input=content)
        if proc.returncode != 0:
            raise OSError(f"Failed to write file {file_path} with privileges")
    else:
        # Normal write
        with open(file_path, 'w') as f:
            f.write(content)


def mkdir_privileged(dir_path: str) -> None:
    """
    Create directory with privilege escalation if needed.

    Args:
        dir_path: Path to directory to create
    """
    # Check if directory path requires privileges (e.g., /mnt/*)
    if dir_path.startswith('/mnt/'):
        # Use pkexec wrapper to create directory as root
        result = subprocess.run(
            [PKEXEC_BIN, PKEXEC_WRAPPER, "mkdir", dir_path],
            capture_output=True
        )
        if result.returncode != 0:
            raise OSError(f"Failed to create directory {dir_path} with privileges: {result.stderr.decode()}")
    else:
        # Normal mkdir
        os.makedirs(dir_path, exist_ok=True)
