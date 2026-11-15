"""
Tests for fleetd's entry point (fleetd/__main__.py), scoped to
`_run_startup_env_check` — the process-start gate on `lib/fleet-env-check.sh`.

Run:
    python3 -m pytest fleet-controller/fleetd/tests/test_main.py -v

Covers issue #341 finding 3: a startup gate failure used to reach only
stderr, which nothing reads for an unattended cron/systemd restart. These
tests assert the Slack notify call fires (or doesn't) alongside the existing
stderr/exit behavior — never in place of it.
"""

import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from fleetd import __main__ as main_mod  # noqa: E402


class TestRunStartupEnvCheck(unittest.TestCase):

    def _run(self, returncode, state_dir='/tmp/fake-state-dir'):
        calls = []
        with mock.patch.object(main_mod, '_notify_gate_stop',
                               lambda *a, **kw: calls.append((a, kw))), \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock, \
             mock.patch.object(sys, 'exit', side_effect=SystemExit) as exit_mock:
            run_mock.return_value = mock.Mock(
                returncode=returncode, stdout='NAME|FAIL|reason', stderr='')
            raised = False
            try:
                main_mod._run_startup_env_check(state_dir)
            except SystemExit:
                raised = True
        return calls, exit_mock.called, raised

    def test_failure_notifies_and_exits(self):
        calls, exited, raised = self._run(returncode=1)
        self.assertTrue(exited)
        self.assertTrue(raised)
        self.assertEqual(len(calls), 1)
        args, kwargs = calls[0]
        # (fleet_lib_dir, state_dir, tid, gate_stop_code, detail)
        self.assertEqual(args[2], main_mod._STARTUP_PSEUDO_TID)
        self.assertEqual(args[3], 'FLEETD_STARTUP_ENV_CHECK_FAILED')

    def test_success_does_not_notify_or_exit(self):
        calls, exited, raised = self._run(returncode=0)
        self.assertFalse(exited)
        self.assertFalse(raised)
        self.assertEqual(calls, [])

    def test_opt_out_skips_the_check_entirely(self):
        with mock.patch.dict('os.environ', {'FLEET_STARTUP_ENV_CHECK': 'false'}), \
             mock.patch.object(main_mod, '_notify_gate_stop') as notify, \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock:
            main_mod._run_startup_env_check('/tmp/fake-state-dir')
        run_mock.assert_not_called()
        notify.assert_not_called()

    def test_missing_state_dir_falls_back_to_resolve_state_dir(self):
        with mock.patch.object(main_mod, '_resolve_state_dir',
                               return_value=Path('/tmp/resolved')) as resolve, \
             mock.patch.object(main_mod, '_notify_gate_stop') as notify, \
             mock.patch.object(main_mod.subprocess, 'run') as run_mock, \
             mock.patch.object(sys, 'exit', side_effect=SystemExit):
            run_mock.return_value = mock.Mock(returncode=1, stdout='', stderr='')
            try:
                main_mod._run_startup_env_check(None)
            except SystemExit:
                pass
        resolve.assert_called_once()
        notify.assert_called_once()
        self.assertEqual(notify.call_args[0][1], Path('/tmp/resolved'))


class TestPhaseDispatchGate(unittest.TestCase):
    """Track 0.5: classify_phase fails a loop-bearing phase closed when no
    verdict was recorded, and only router-step.sh post-spawn records one on
    the phase-dispatch path. Phase dispatch without FLEET_ROUTER_STEP_SHELL
    would fail every VERIFY, so fleetd refuses to start that combination."""

    def _gate(self, env):
        calls = []
        with mock.patch.dict('os.environ', env, clear=False), \
             mock.patch.object(main_mod, '_notify_gate_stop',
                               lambda *a, **kw: calls.append(a)), \
             mock.patch.object(sys, 'exit', side_effect=SystemExit) as exit_mock:
            raised = False
            try:
                main_mod._run_phase_dispatch_gate('/tmp/fake-state-dir')
            except SystemExit:
                raised = True
        return calls, exit_mock.called and raised

    def test_phase_dispatch_without_router_steps_refuses_to_start(self):
        for router in ('false', '', 'TRUE', '1'):
            with self.subTest(router=router):
                calls, exited = self._gate({
                    'FLEET_PHASE_DISPATCH_ENABLE': 'true',
                    'FLEET_ROUTER_STEP_SHELL': router})
                self.assertTrue(exited)
                self.assertEqual(len(calls), 1)
                self.assertEqual(calls[0][3],
                                 'FLEETD_PHASE_DISPATCH_NEEDS_ROUTER_STEP')

    def test_phase_dispatch_with_router_steps_starts(self):
        calls, exited = self._gate({'FLEET_PHASE_DISPATCH_ENABLE': 'true',
                                    'FLEET_ROUTER_STEP_SHELL': 'true'})
        self.assertFalse(exited)
        self.assertEqual(calls, [])

    def test_ticket_level_dispatch_is_unaffected(self):
        for router in ('true', 'false'):
            with self.subTest(router=router):
                calls, exited = self._gate({
                    'FLEET_PHASE_DISPATCH_ENABLE': 'false',
                    'FLEET_ROUTER_STEP_SHELL': router})
                self.assertFalse(exited)
                self.assertEqual(calls, [])

    def test_the_env_check_opt_out_does_not_skip_it(self):
        calls, exited = self._gate({'FLEET_PHASE_DISPATCH_ENABLE': 'true',
                                    'FLEET_ROUTER_STEP_SHELL': 'false',
                                    'FLEET_STARTUP_ENV_CHECK': 'false'})
        self.assertTrue(exited)

    def test_main_runs_the_gate_before_building_the_supervisor(self):
        order = []
        with mock.patch.object(main_mod, '_run_startup_env_check',
                               lambda *a: order.append('env')), \
             mock.patch.object(main_mod, '_run_phase_dispatch_gate',
                               lambda *a: order.append('phase')), \
             mock.patch.object(main_mod, 'Supervisor') as sup_cls, \
             mock.patch.object(sys, 'argv', ['fleetd']):
            sup_cls.side_effect = lambda **kw: order.append('sup') or mock.Mock()
            main_mod.main()
        self.assertEqual(order, ['env', 'phase', 'sup'])


if __name__ == '__main__':
    unittest.main()
