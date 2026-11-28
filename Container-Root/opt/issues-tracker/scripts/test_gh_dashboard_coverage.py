import importlib.util
import json
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock
HERE = Path(__file__).resolve().parent
os.environ.setdefault('ISSUES_GH_LOGIN', 'octocat')

def _load_dashboard():
    spec = importlib.util.spec_from_file_location('ghdash_under_test', HERE / 'gh-dashboard.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def _fake_pr(repo, num, state='OPEN'):
    return {'__typename': 'PullRequest', 'repo': repo, 'number': num, 'state': state, 'title': 't', 'author': {'login': 'octocat'}, 'isDraft': False, 'updatedAt': '2000-08-09T02:35:20Z', 'comments': {'nodes': []}, 'reviews': {'nodes': []}, 'reviewThreads': {'nodes': []}, 'commits': {'nodes': [{'commit': {'statusCheckRollup': {'state': 'SUCCESS', 'contexts': {'nodes': []}}}}]}, 'mergeStateStatus': 'CLEAN', 'reviewDecision': None, 'mergedAt': None}

class MainCoverageWiringTest(unittest.TestCase):

    def setUp(self):
        self.m = _load_dashboard()
        self.d = Path(tempfile.mkdtemp(prefix='ghdash-'))
        self.addCleanup(shutil.rmtree, self.d, True)
        self.m.OUT_DIR = self.d
        self.state = self.d / 'state.json'
        self.log = self.d / 'loop-log.jsonl'

    def _run_main(self, argv=('gh-dashboard.py',)):
        with mock.patch.object(sys, 'argv', list(argv)):
            self.m.main()

    def test_blackout_preserves_last_known_good_and_exits_nonzero(self):
        prior = {'generated': '2000-08-10T19:40:30Z', 'items': [{'repo': 'a/b', 'number': 1, 'state': 'OPEN', 'we_owe': True}, {'repo': 'c/d', 'number': 2, 'state': 'OPEN', 'we_owe': False}]}
        self.state.write_text(json.dumps(prior))
        self.m.build_inventory = lambda **kw: ([('a/b', 1), ('c/d', 2)], 30, 30)
        self.m.pull = lambda item: None
        with self.assertRaises(SystemExit) as cm:
            self._run_main()
        self.assertEqual(cm.exception.code, 3)
        after = json.loads(self.state.read_text())
        self.assertEqual(len(after['items']), 2)
        recs = [json.loads(l) for l in self.log.read_text().splitlines() if l.strip()]
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]['outcome'], 'blocked_no_visibility')
        self.assertEqual(recs[0]['scope'], 'scan')
        self.assertNotIn('number', recs[0])

    def test_total_inventory_blackout_is_blocked(self):
        prior = {'generated': 'x', 'items': [{'repo': 'a/b', 'number': 1}]}
        self.state.write_text(json.dumps(prior))
        self.m.build_inventory = lambda **kw: ([], 64, 0)
        self.m.pull = lambda item: _fake_pr(*item)
        with self.assertRaises(SystemExit) as cm:
            self._run_main()
        self.assertEqual(cm.exception.code, 3)
        self.assertEqual(len(json.loads(self.state.read_text())['items']), 1)

    def test_healthy_scan_writes_state_with_coverage_embedded(self):
        self.m.build_inventory = lambda **kw: ([('a/b', 1), ('c/d', 2)], 30, 30)
        self.m.pull = lambda item: _fake_pr(*item)
        self._run_main()
        after = json.loads(self.state.read_text())
        self.assertEqual(len(after['items']), 2)
        self.assertEqual(after['scan_outcome'], 'complete')
        self.assertEqual(after['coverage']['coverage'], 1.0)
        self.assertEqual(after['coverage']['items_seen'], 2)
        self.assertTrue((self.d / 'DASHBOARD.md').exists())

    def test_all_closed_open_only_scan_is_not_a_blackout(self):
        self.m.build_inventory = lambda **kw: ([('a/b', 1), ('c/d', 2)], 30, 30)
        self.m.pull = lambda item: _fake_pr(*item, state='CLOSED')
        self._run_main(argv=('gh-dashboard.py', '--open-only'))
        after = json.loads(self.state.read_text())
        self.assertEqual(after['items'], [])
        self.assertEqual(after['scan_outcome'], 'complete')
        self.assertEqual(after['coverage']['items_seen'], 2)

    def test_partial_scan_preserves_last_known_good_and_exits_nonzero(self):
        self.state.write_text(json.dumps({'generated': 'prior', 'items': [{'repo': 'a/b', 'number': 1}, {'repo': 'c/d', 'number': 2}, {'repo': 'e/f', 'number': 3}]}))
        self.m.build_inventory = lambda **kw: ([('a/b', 1), ('c/d', 2), ('e/f', 3), ('g/h', 4)], 30, 30)
        self.m.pull = lambda it: _fake_pr(*it) if it[1] % 2 else None
        with mock.patch.object(self.m.time, 'sleep', lambda s: None):
            with self.assertRaises(SystemExit) as cm:
                self._run_main()
        self.assertEqual(cm.exception.code, 3)
        self.assertEqual(len(json.loads(self.state.read_text())['items']), 3, 'prior board intact')
        self.assertTrue((self.d / 'state.partial.json').exists())

    def test_the_partial_flag_writes_the_partial_state(self):
        self.m.build_inventory = lambda **kw: ([('a/b', 1), ('c/d', 2), ('e/f', 3), ('g/h', 4)], 30, 30)
        self.m.pull = lambda it: _fake_pr(*it) if it[1] % 2 else None
        with mock.patch.object(self.m.time, 'sleep', lambda s: None):
            self._run_main(argv=('gh-dashboard.py', '--allow-partial'))
        after = json.loads(self.state.read_text())
        self.assertEqual(after['scan_outcome'], 'partial')
        self.assertEqual(len(after['items']), 2)

    def test_pull_loop_is_paced_one_request_at_a_time(self):
        items = [('a/b', n) for n in range(1, 36)]
        self.m.build_inventory = lambda **kw: (items, 30, 30)
        self.m.pull = lambda it: _fake_pr(*it)
        sleeps = []
        env = {'DASH_PACE_SEC': '0.5', 'DASH_BURST_N': '30', 'DASH_BURST_PAUSE_SEC': '7'}
        with mock.patch.dict(self.m.os.environ, env), mock.patch.object(self.m.time, 'sleep', sleeps.append):
            self._run_main()
        self.assertEqual(sleeps.count(0.5), 34, sleeps)
        self.assertEqual(sleeps.count(7.0), 1, sleeps)

    def test_fetch_backs_off_once_on_a_secondary_rate_limit(self):
        calls = []

        def fake_run(argv, **kw):
            calls.append(argv)
            if len(calls) == 1:
                return mock.Mock(returncode=1, stdout='', stderr='You have exceeded a secondary rate limit')
            return mock.Mock(returncode=0, stderr='', stdout=json.dumps({'data': {'repository': {'issueOrPullRequest': {'__typename': 'Issue', 'number': 7}}}}))
        sleeps = []
        with mock.patch.dict(self.m.os.environ, {'DASH_BACKOFF_SEC': '9'}), mock.patch.object(self.m.subprocess, 'run', fake_run), mock.patch.object(self.m.time, 'sleep', sleeps.append):
            got = self.m._fetch('o', 'r', 7)
        self.assertEqual(len(calls), 2, 'one retry after the backoff')
        self.assertEqual(sleeps, [9.0])
        self.assertEqual(got['number'], 7)

    def test_open_only_inventory_searches_only_open_items(self):
        calls = []

        def fake_run(argv, **kw):
            calls.append(' '.join(argv))
            if any(('search/issues' in a for a in argv)):
                return mock.Mock(returncode=0, stdout=json.dumps({'items': []}), stderr='')
            return mock.Mock(returncode=0, stdout='[]', stderr='')
        with mock.patch.object(self.m.subprocess, 'run', fake_run):
            self.m.build_inventory(states=('open',))
        search = [c for c in calls if 'search/issues' in c]
        self.assertTrue(search and all(('is:open' in c for c in search)), search)
        self.assertFalse(any(('is:closed' in c for c in search)), 'open-only must not search closed items')
        calls.clear()
        with mock.patch.object(self.m.subprocess, 'run', fake_run):
            self.m.build_inventory()
        self.assertTrue(any(('is:closed' in c for c in calls)), 'default inventory still covers closed items')

    def test_open_only_flag_wires_the_open_inventory(self):
        seen = {}

        def fake_inv(**kw):
            seen.update(kw)
            return ([('a/b', 1)], 10, 10)
        self.m.build_inventory = fake_inv
        self.m.pull = lambda it: _fake_pr(*it)
        with mock.patch.object(self.m.time, 'sleep', lambda s: None):
            self._run_main(argv=('gh-dashboard.py', '--open-only'))
        self.assertEqual(seen.get('states'), ('open',))

class OperatorLoginIsConfiguration(unittest.TestCase):

    def test_a_env_var_sets_me(self):
        with mock.patch.dict(os.environ, {'ISSUES_GH_LOGIN': 'octocat'}):
            m = _load_dashboard()
        self.assertEqual(m.ME, 'octocat')

    def test_b_unset_env_means_no_literal_default(self):
        env = {k: v for k, v in os.environ.items() if k != 'ISSUES_GH_LOGIN'}
        with mock.patch.dict(os.environ, env, clear=True):
            m = _load_dashboard()
        self.assertEqual(m.ME, '', 'ME must not default to a hard-coded login')

    def test_c_resolve_login_asks_gh_once_and_caches(self):
        env = {k: v for k, v in os.environ.items() if k != 'ISSUES_GH_LOGIN'}
        with mock.patch.dict(os.environ, env, clear=True):
            m = _load_dashboard()
        calls = []

        def fake_run(argv, *a, **kw):
            calls.append(argv)
            return mock.Mock(returncode=0, stdout='octocat2\n', stderr='')
        with mock.patch.object(m.subprocess, 'run', side_effect=fake_run):
            self.assertEqual(m.resolve_login(), 'octocat2')
            self.assertEqual(m.ME, 'octocat2')
            self.assertEqual(m.resolve_login(), 'octocat2')
        self.assertEqual(len(calls), 1, 'one gh call, then cached')
        self.assertTrue(any(('user' in a for a in calls[0])), calls[0])
if __name__ == '__main__':
    unittest.main()
