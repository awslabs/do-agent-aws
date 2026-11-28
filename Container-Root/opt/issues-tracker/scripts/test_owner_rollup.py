#!/usr/bin/env python3
import importlib.util
import os
import unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
os.environ.setdefault('ISSUES_GH_LOGIN', 'octocat')

def _load():
    spec = importlib.util.spec_from_file_location('ghdash_owner_ut', HERE / 'gh-dashboard.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def _row(**kw):
    base = {'repo': 'o/r', 'number': 1, 'title': 't', 'type': 'PR', 'state': 'OPEN', 'merged': False, 'is_draft': False, 'is_ours': True, 'author': 'octocat', 'merge_state': 'CLEAN', 'review_decision': None, 'we_owe': False, 'ci_state': 'SUCCESS', 'ci_failures': None, 'needs_attention': False, 'attn_reasons': [], 'bucket': None, 'days_idle': 1, 'updated': '2000-09-14', 'unresolved_threads': 0, 'last_them': None, 'no_engagement': True}
    base.update(kw)
    return base

class ClassifyOwnerTest(unittest.TestCase):

    def setUp(self):
        self.m = _load()

    def test_we_owe_is_ours_act_even_when_not_ours(self):
        r = _row(is_ours=False, author='someone', we_owe=True, no_engagement=False, last_them={'t': 'x', 'who': 'maint', 'body': '?'})
        self.assertEqual(self.m.classify_owner(r), 'ours-act')

    def test_our_onfire_pr_with_no_comment_is_ours_act_not_watch(self):
        r = _row(is_ours=True, we_owe=False, no_engagement=True, needs_attention=True, merge_state='DIRTY', attn_reasons=['merge-conflict (needs rebase)'], bucket='D-conflict')
        self.assertEqual(self.m.classify_owner(r), 'ours-act')

    def test_our_healthy_pr_ball_in_their_court_is_maintainers(self):
        r = _row(is_ours=True, we_owe=False, no_engagement=False, needs_attention=False, review_decision='REVIEW_REQUIRED', last_them={'t': 'x', 'who': 'maint', 'body': 'lgtm soon'})
        self.assertEqual(self.m.classify_owner(r), 'maintainers')

    def test_not_ours_engaged_ball_in_their_court_is_upstream(self):
        r = _row(is_ours=False, author='them', we_owe=False, no_engagement=False, last_them={'t': 'x', 'who': 'them', 'body': 'thanks'})
        self.assertEqual(self.m.classify_owner(r), 'upstream')

    def test_zero_engagement_is_watch(self):
        r = _row(is_ours=True, we_owe=False, no_engagement=True, needs_attention=False)
        self.assertEqual(self.m.classify_owner(r), 'watch')

    def test_mece_every_row_lands_in_exactly_one_known_bucket(self):
        known = {'ours-act', 'maintainers', 'upstream', 'watch'}
        seen = set()
        for is_ours in (True, False):
            for we_owe in (True, False):
                for needs in (True, False):
                    for no_eng in (True, False):
                        r = _row(is_ours=is_ours, we_owe=we_owe, needs_attention=needs, no_engagement=no_eng)
                        b = self.m.classify_owner(r)
                        self.assertIn(b, known, f'bad bucket {b!r} for {r}')
                        seen.add(b)
        self.assertEqual(seen, known)

class RenderRollupTest(unittest.TestCase):

    def setUp(self):
        self.m = _load()

    def test_render_emits_per_owner_rollup_with_counts(self):
        rows = [_row(number=1, is_ours=True, we_owe=True, no_engagement=False, last_them={'t': 'x', 'who': 'm', 'body': '?'}), _row(number=2, is_ours=True, needs_attention=True, merge_state='DIRTY', bucket='D-conflict'), _row(number=3, is_ours=True, no_engagement=False, review_decision='REVIEW_REQUIRED', last_them={'t': 'x', 'who': 'm', 'body': 'ok'}), _row(number=4, is_ours=False, author='them', no_engagement=False, last_them={'t': 'x', 'who': 'them', 'body': 'hi'}), _row(number=5, is_ours=True, no_engagement=True)]
        out = self.m.render(rows, '2000-09-15 08:04 UTC')
        self.assertIn('Per-owner rollup', out)
        self.assertIn('ours-act', out)
        self.assertIn('maintainers', out)
        self.assertIn('upstream', out)
        self.assertRegex(out, 'ours-act[^\\n]*\\b2\\b')
if __name__ == '__main__':
    unittest.main(verbosity=2)
