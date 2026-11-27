import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import scan_coverage as sc

class CoverageProofTest(unittest.TestCase):

    def test_coverage_value_is_the_success_ratio(self):
        p = sc.coverage_proof(channels_attempted=10, channels_succeeded=7, items_seen=42)
        self.assertAlmostEqual(p['coverage'], 0.7)
        self.assertEqual(p['items_seen'], 42)
        self.assertEqual(p['channels_attempted'], 10)
        self.assertEqual(p['channels_succeeded'], 7)

    def test_no_channels_attempted_is_zero_coverage(self):
        p = sc.coverage_proof(channels_attempted=0, channels_succeeded=0, items_seen=0)
        self.assertEqual(p['coverage'], 0.0)

    def test_succeeded_cannot_exceed_attempted(self):
        with self.assertRaises(ValueError):
            sc.coverage_proof(channels_attempted=3, channels_succeeded=5, items_seen=1)

class ScanOutcomeTest(unittest.TestCase):

    def test_zero_coverage_is_hard_error(self):
        p = sc.coverage_proof(channels_attempted=64, channels_succeeded=0, items_seen=0)
        self.assertEqual(sc.scan_outcome(p), sc.BLOCKED)

    def test_zero_rows_is_blocked_even_with_partial_channel_success(self):
        p = sc.coverage_proof(channels_attempted=64, channels_succeeded=9, items_seen=0)
        self.assertGreater(p['coverage'], 0.0)
        self.assertEqual(sc.scan_outcome(p), sc.BLOCKED)

    def test_partial_coverage_is_flagged_not_complete(self):
        p = sc.coverage_proof(channels_attempted=64, channels_succeeded=61, items_seen=47)
        self.assertEqual(sc.scan_outcome(p), sc.PARTIAL)

    def test_full_coverage_with_rows_is_complete(self):
        p = sc.coverage_proof(channels_attempted=64, channels_succeeded=64, items_seen=52)
        self.assertEqual(sc.scan_outcome(p), sc.COMPLETE)

class BlockedOpsRecordTest(unittest.TestCase):

    def test_blocked_record_is_ops_scoped_never_a_per_item_needs_human(self):
        p = sc.coverage_proof(0, 0, 0)
        rec = sc.blocked_ops_record(p, ts='2000-04-04T21:44:41Z')
        self.assertEqual(rec['outcome'], sc.BLOCKED)
        self.assertEqual(rec.get('channel'), 'ops')
        self.assertEqual(rec.get('scope'), 'scan')
        self.assertNotIn('number', rec)
        self.assertNotEqual(rec['outcome'], 'needs-human')
        self.assertIn('coverage', rec)

class PersistStateTest(unittest.TestCase):

    def _tmp(self):
        import tempfile
        d = Path(tempfile.mkdtemp(prefix='scancov-'))
        self.addCleanup(shutil.rmtree, d, True)
        return (d, d / 'state.json', d / 'loop-log.jsonl')

    def test_blocked_scan_preserves_prior_nonempty_state(self):
        d, state_path, log_path = self._tmp()
        prior = {'generated': '2000-03-13T18:37:34Z', 'items': [{'repo': 'a/b', 'number': 1, 'we_owe': True}, {'repo': 'c/d', 'number': 2, 'we_owe': False}]}
        state_path.write_text(json.dumps(prior))
        p = sc.coverage_proof(64, 0, 0)
        wrote = sc.persist_scan_state(sc.BLOCKED, p, state_payload={'generated': '2000-04-04T21:44:41Z', 'items': []}, state_path=state_path, log_path=log_path, ts='2000-04-04T21:44:41Z')
        self.assertFalse(wrote, 'BLOCKED must NOT write state.json')
        after = json.loads(state_path.read_text())
        self.assertEqual(len(after['items']), 2)
        recs = [json.loads(l) for l in log_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]['outcome'], sc.BLOCKED)
        self.assertEqual(recs[0]['scope'], 'scan')
        self.assertTrue(all((r['outcome'] != 'needs-human' for r in recs)))
        self.assertTrue(all(('number' not in r for r in recs)))

    def test_complete_scan_writes_state_with_coverage_embedded(self):
        d, state_path, log_path = self._tmp()
        p = sc.coverage_proof(64, 64, 52)
        payload = {'generated': '2000-04-04T21:44:41Z', 'items': [{'repo': 'a/b', 'number': 1}]}
        wrote = sc.persist_scan_state(sc.COMPLETE, p, state_payload=payload, state_path=state_path, log_path=log_path, ts='2000-04-04T21:44:41Z')
        self.assertTrue(wrote)
        after = json.loads(state_path.read_text())
        self.assertEqual(len(after['items']), 1)
        self.assertEqual(after['coverage']['coverage'], 1.0)
        self.assertEqual(after['scan_outcome'], sc.COMPLETE)
        self.assertFalse(log_path.exists() and log_path.read_text().strip())

    def test_partial_scan_preserves_prior_state_and_sidecars_the_partial(self):
        d, state_path, log_path = self._tmp()
        prior = {'generated': '2000-12-14T03:12:42Z', 'items': [{'repo': 'a/b', 'number': 1}, {'repo': 'c/d', 'number': 2}]}
        state_path.write_text(json.dumps(prior))
        p = sc.coverage_proof(300, 51, 44)
        payload = {'generated': '2000-12-22T07:48:13Z', 'items': [{'repo': 'a/b', 'number': 1}]}
        wrote = sc.persist_scan_state(sc.PARTIAL, p, state_payload=payload, state_path=state_path, log_path=log_path, ts='2000-12-22T07:48:13Z')
        self.assertFalse(wrote, 'PARTIAL must NOT overwrite state.json by default')
        after = json.loads(state_path.read_text())
        self.assertEqual(len(after['items']), 2, 'last-known-good board must be intact')
        side = state_path.with_name('state.partial.json')
        self.assertTrue(side.exists(), 'the partial result must be parked for inspection')
        parked = json.loads(side.read_text())
        self.assertEqual(parked['scan_outcome'], sc.PARTIAL)
        self.assertEqual(len(parked['items']), 1)
        recs = [json.loads(l) for l in log_path.read_text().splitlines() if l.strip()]
        self.assertEqual(len(recs), 1)
        self.assertEqual(recs[0]['outcome'], sc.PARTIAL_PRESERVED)
        self.assertEqual(recs[0]['scope'], 'scan')
        self.assertTrue(all(('number' not in r for r in recs)))

    def test_partial_scan_writes_only_when_explicitly_allowed(self):
        d, state_path, log_path = self._tmp()
        p = sc.coverage_proof(64, 61, 47)
        payload = {'generated': '2000-04-04T21:44:41Z', 'items': [{'repo': 'a/b', 'number': 1}]}
        wrote = sc.persist_scan_state(sc.PARTIAL, p, state_payload=payload, state_path=state_path, log_path=log_path, ts='2000-04-04T21:44:41Z', partial_ok=True)
        self.assertTrue(wrote, 'an explicit --allow-partial is the operator saying: write it anyway')
        after = json.loads(state_path.read_text())
        self.assertEqual(after['scan_outcome'], sc.PARTIAL)
        self.assertLess(after['coverage']['coverage'], 1.0)
if __name__ == '__main__':
    unittest.main()
