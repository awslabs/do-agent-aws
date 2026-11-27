#!/usr/bin/env python3
import importlib.util
import os
import unittest
from unittest import mock
import tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
os.environ.setdefault('ISSUES_GH_LOGIN', 'octocat')

def _load():
    spec = importlib.util.spec_from_file_location('ghdash_upstream_ut', HERE / 'gh-dashboard.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def _pr(**kw):
    ci = kw.pop('ci_contexts', None)
    ci_state = kw.pop('ci_state', 'FAILURE')
    i = {'__typename': 'PullRequest', 'repo': 'o/r', 'number': 1, 'title': 't', 'state': 'OPEN', 'isDraft': False, 'mergedAt': None, 'closedAt': None, 'updatedAt': '2000-07-21T10:36:08Z', 'author': {'login': 'octocat'}, 'mergeStateStatus': 'CLEAN', 'reviewDecision': None, 'comments': {'nodes': []}, 'reviewThreads': {'nodes': []}, 'commits': {'nodes': [{'commit': {'statusCheckRollup': None}}]}}
    if ci is not None:
        i['commits'] = {'nodes': [{'commit': {'statusCheckRollup': {'state': ci_state, 'contexts': {'nodes': [{'__typename': 'CheckRun', 'name': n, 'conclusion': c, 'detailsUrl': ''} for n, c in ci]}}}}]}
    i.update(kw)
    return i

class UpstreamDeltaTest(unittest.TestCase):

    def setUp(self):
        self.m = _load()

    def test_t1_approved_dirty_is_approved_stuck_bucket(self):
        r = self.m.classify(_pr(reviewDecision='APPROVED', mergeStateStatus='DIRTY'))
        self.assertTrue(r['needs_attention'])
        self.assertEqual(r['bucket'], 'A-approved-stuck')

    def test_t2_approved_stuck_outranks_d_conflict(self):
        r = self.m.classify(_pr(reviewDecision='APPROVED', mergeStateStatus='CONFLICTING'))
        self.assertEqual(r['bucket'], 'A-approved-stuck')

    def test_t2b_approved_behind_is_also_stale(self):
        r = self.m.classify(_pr(reviewDecision='APPROVED', mergeStateStatus='BEHIND'))
        self.assertEqual(r['bucket'], 'A-approved-stuck')
        self.assertTrue(r['needs_attention'])

    def test_t1_negative_dirty_but_not_approved_stays_d_conflict(self):
        r = self.m.classify(_pr(reviewDecision='REVIEW_REQUIRED', mergeStateStatus='DIRTY'))
        self.assertEqual(r['bucket'], 'D-conflict')

    def test_t3_action_required_is_not_red_ci(self):
        r = self.m.classify(_pr(ci_state='ACTION_REQUIRED', ci_contexts=[('Build', 'ACTION_REQUIRED')]))
        self.assertIsNone(r['ci_failures'])
        self.assertNotEqual(r['bucket'], 'C-red-ci')
        self.assertFalse(r['needs_attention'])

    def test_t4_genuine_failure_still_red(self):
        r = self.m.classify(_pr(ci_state='FAILURE', ci_contexts=[('Build', 'FAILURE')]))
        self.assertIsNotNone(r['ci_failures'])
        self.assertEqual(r['bucket'], 'C-red-ci')
        self.assertTrue(r['needs_attention'])

    def test_t5_needs_repoll_only_on_unknown_pr(self):
        self.assertTrue(self.m.needs_repoll(_pr(mergeStateStatus='UNKNOWN')))
        self.assertFalse(self.m.needs_repoll(_pr(mergeStateStatus='CLEAN')))
        self.assertFalse(self.m.needs_repoll(_pr(mergeStateStatus='DIRTY')))
        self.assertFalse(self.m.needs_repoll(None))
        self.assertFalse(self.m.needs_repoll({'__typename': 'Issue', 'mergeStateStatus': None}))
        self.assertFalse(self.m.needs_repoll({'__typename': 'Issue', 'mergeStateStatus': 'UNKNOWN'}))

    def test_t7_service_and_triage_bots_never_create_we_owe(self):
        with tempfile.TemporaryDirectory() as tmp:
            site = Path(tmp) / 'site.local.conf'
            site.write_text("BOT_LOGINS='svc-example|triage-helper'\n")
            with mock.patch.dict(os.environ, {'SHIPPED_TREE_DENYLIST_FILE': str(site)}):
                with_site = _load()
            with mock.patch.dict(os.environ, {'SHIPPED_TREE_DENYLIST_FILE': str(Path(tmp) / 'absent.conf')}):
                generic = _load()
        for m, bots, humans in ((with_site, ('svc-example', 'triage-helper'), ('example-triage[bot]', 'some-person')), (generic, ('example-triage[bot]', 'github-actions'), ('svc-example', 'some-person'))):
            for who in bots + humans:
                r = m.classify(_pr(comments={'nodes': [{'author': {'login': who}, 'createdAt': '2000-07-03T12:33:29Z', 'body': 'triage'}]}))
                if who in bots:
                    self.assertFalse(r['we_owe'], f'{who} comment must not set we_owe')
                    self.assertTrue(r['no_engagement'], f'{who} is not engagement')
                else:
                    self.assertTrue(r['we_owe'], f'{who} is a person waiting on us')

class RenderPriorityTest(unittest.TestCase):

    def setUp(self):
        self.m = _load()

    def test_t6_approved_stuck_sorts_above_d_conflict_even_when_older(self):
        rows = [self.m.classify(_pr(number=10, mergeStateStatus='DIRTY', reviewDecision='REVIEW_REQUIRED', updatedAt='2000-07-21T10:36:08Z')), self.m.classify(_pr(number=20, mergeStateStatus='DIRTY', reviewDecision='APPROVED', updatedAt='2000-06-30T20:54:09Z'))]
        out = self.m.render(rows, '2000-07-22 21:38 UTC')
        i20 = out.index('#20]')
        i10 = out.index('#10]')
        self.assertLess(i20, i10, 'A-approved-stuck must sort above D-conflict')
if __name__ == '__main__':
    unittest.main(verbosity=2)
