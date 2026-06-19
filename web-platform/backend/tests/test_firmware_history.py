"""Regression tests for firmware pending-activation detection
(resolvers/firmware.py).

The key regression this pins: fwupd's `get-history --json` serialises
`UpdateState` as the raw FwupdUpdateState *integer* (e.g. 2 == success),
NOT the string name. The original code did `(d.get("UpdateState") or
"").lower()`, which raised `'int' object has no attribute 'lower'` and
500'd the entire /api/hardware/overview endpoint for any box that had
firmware history — the Hardware page rendered nothing but the error.
"""
import json

from resolvers.firmware import _has_pending_activation, _update_state


def test_update_state_handles_int_enum():
    # The shape fwupd actually emits in --json: integer enum values.
    assert _update_state(0) == "unknown"
    assert _update_state(1) == "pending"
    assert _update_state(2) == "success"
    assert _update_state(4) == "needs-reboot"
    # Out-of-range / unknown int normalises to "" (membership test False),
    # never crashes.
    assert _update_state(99) == ""


def test_update_state_handles_string_and_junk():
    # Defensive: older fwupd / hand-built fixtures may use strings.
    assert _update_state("pending") == "pending"
    assert _update_state("NEEDS-REBOOT") == "needs-reboot"
    # bool is an int subclass but is never a valid state.
    assert _update_state(True) == ""
    assert _update_state(None) == ""


def test_no_history_is_not_pending():
    # Clean system: fwupd returns an Error object, no Devices.
    assert _has_pending_activation('{"Error":{"Message":"No history"}}') is False
    assert _has_pending_activation("") is False
    assert _has_pending_activation("not json") is False


def test_success_history_does_not_crash_and_is_not_pending():
    # The exact failure mode: a device whose UpdateState is the integer 2
    # (success). Must NOT raise, and a completed update is not "pending".
    hist = json.dumps({"Devices": [{"Name": "UEFI CA", "UpdateState": 2}]})
    assert _has_pending_activation(hist) is False


def test_pending_int_states_detected():
    # pending (1) and needs-reboot (4), both at device level and embedded
    # in a Release, are the "reboot to finish installing" signal.
    assert _has_pending_activation(
        json.dumps({"Devices": [{"Name": "X", "UpdateState": 1}]})) is True
    assert _has_pending_activation(
        json.dumps({"Devices": [{"Name": "X", "UpdateState": 4}]})) is True
    assert _has_pending_activation(json.dumps({
        "Devices": [{"Name": "X", "UpdateState": 2,
                     "Releases": [{"UpdateState": 4}]}]})) is True


def test_blocked_release_is_skipped():
    # A release flagged blocked-version must not count as pending even if
    # its UpdateState says needs-reboot.
    assert _has_pending_activation(json.dumps({
        "Devices": [{"Name": "X", "UpdateState": 2,
                     "Releases": [{"UpdateState": 4,
                                   "Flags": ["blocked-version"]}]}]})) is False
