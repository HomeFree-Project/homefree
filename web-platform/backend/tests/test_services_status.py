"""Unit tests for the systemd status aggregation in
resolvers/services.py (_get_systemd_status).

The socket-activation case is the key behavior this pins: a
socket-activated service (e.g. cockpit) sits inactive/dead between
connections while its .socket holds the listener and idle-exits cleanly
after use. The resolver must report it as healthy ("active"/"running",
the green dot) when the triggering socket is armed — NOT as Stopped —
while a unit that is inactive with a dead/absent socket, or one whose
on-demand start crashed (failed), still reports honestly.

`systemctl show` is faked per-unit — there is no systemd in the test
sandbox.
"""
import resolvers.services as services_mod
from resolvers.services import ServicesResolver


class _Result:
    def __init__(self, stdout, returncode=0):
        self.returncode = returncode
        self.stdout = stdout
        self.stderr = ""


def _patch_systemctl(monkeypatch, units):
    """Fake `systemctl show <unit> --property=A,B,C` from a per-unit
    property dict. Unknown units answer the way real systemctl does:
    LoadState=not-found, inactive/dead, rc=0."""

    def fake_run(cmd, **_kwargs):
        assert cmd[:2] == ['systemctl', 'show']
        unit = cmd[2]
        wanted = cmd[3].split('=', 1)[1].split(',')
        props = units.get(unit, {
            'ActiveState': 'inactive',
            'SubState': 'dead',
            'LoadState': 'not-found',
            'TriggeredBy': '',
        })
        lines = [f"{p}={props.get(p, '')}" for p in wanted]
        return _Result("\n".join(lines))

    monkeypatch.setattr(services_mod.subprocess, 'run', fake_run)


def test_socket_armed_unit_counts_as_running(monkeypatch):
    _patch_systemctl(monkeypatch, {
        'cockpit': {
            'ActiveState': 'inactive', 'SubState': 'dead',
            'LoadState': 'loaded', 'TriggeredBy': 'cockpit.socket',
        },
        'cockpit.socket': {'ActiveState': 'active'},
    })
    active, sub, unit_states = ServicesResolver._get_systemd_status(['cockpit'])
    assert (active, sub) == ('active', 'running')
    # Per-unit state still reports reality (blue/green convention).
    assert unit_states[0].active_state == 'inactive'


def test_socket_dead_unit_stays_stopped(monkeypatch):
    _patch_systemctl(monkeypatch, {
        'cockpit': {
            'ActiveState': 'inactive', 'SubState': 'dead',
            'LoadState': 'loaded', 'TriggeredBy': 'cockpit.socket',
        },
        'cockpit.socket': {'ActiveState': 'inactive'},
    })
    active, sub, _ = ServicesResolver._get_systemd_status(['cockpit'])
    assert (active, sub) == ('inactive', 'dead')


def test_failed_unit_not_masked_by_armed_socket(monkeypatch):
    # A crashed on-demand start must stay visible as failed even though
    # the socket is still listening.
    _patch_systemctl(monkeypatch, {
        'cockpit': {
            'ActiveState': 'failed', 'SubState': 'failed',
            'LoadState': 'loaded', 'TriggeredBy': 'cockpit.socket',
        },
        'cockpit.socket': {'ActiveState': 'active'},
    })
    active, sub, _ = ServicesResolver._get_systemd_status(['cockpit'])
    assert (active, sub) == ('failed', 'failed')


def test_plain_inactive_unit_without_trigger_stays_stopped(monkeypatch):
    _patch_systemctl(monkeypatch, {
        'someapp': {
            'ActiveState': 'inactive', 'SubState': 'dead',
            'LoadState': 'loaded', 'TriggeredBy': '',
        },
    })
    active, sub, _ = ServicesResolver._get_systemd_status(['someapp'])
    assert (active, sub) == ('inactive', 'dead')


def test_running_unit_unaffected(monkeypatch):
    _patch_systemctl(monkeypatch, {
        'someapp': {
            'ActiveState': 'active', 'SubState': 'running',
            'LoadState': 'loaded', 'TriggeredBy': '',
        },
    })
    active, sub, _ = ServicesResolver._get_systemd_status(['someapp'])
    assert (active, sub) == ('active', 'running')
