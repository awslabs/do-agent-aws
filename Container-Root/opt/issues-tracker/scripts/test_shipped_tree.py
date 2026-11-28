#!/usr/bin/env python3
import os
import re
import sys
import unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
IS_EXPORT = (REPO / 'EXPORT-VERSION').exists()
SITE_FILE = Path(os.environ.get('SHIPPED_TREE_DENYLIST_FILE') or HERE / 'test_shipped_tree.local.conf')
SHIPPED_AGENTS = []
SHIPPED_SKILLS = []
POST_VERB = re.compile('(^|[`$\\s])gh (pr|issue) (comment|create|edit|close|merge|review|ready|reopen|delete|lock)\\b')
API = re.compile('(^|[`$\\s])gh api\\b(?P<rest>[^`\\n]*)')
API_WRITE_FLAG = re.compile('(^|\\s)(-X|--method(=|\\s)|-XPOST|-XPATCH|-XPUT|-XDELETE|--input\\b)')
API_FIELD = re.compile('(^|\\s)(-f|-F|--field|--raw-field)(=|\\s)')
MCP_WRITE = re.compile('\\b(issue_write|pull_request_review_write|sub_issue_write|merge_pull_request|create_pull_request|push_files|create_or_update_file|add_issue_comment|add_comment_to_pending_review|update_pull_request|update_issue_comment|delete_repository|fork_repository|create_branch|create_repository|request_copilot_review)\\b')
POST_PROSE = re.compile('close-with-comment|post\\s*>\\s*\\d+\\s*comments?|comments? (per|quota)|reply / fix\\+push', re.I)
LEARNING_ID = re.compile('\\bISSUE-[A-Z]+-\\d+\\b')
QUALIFIED_REF = re.compile('(?<![\\w.-])(?P<owner>[A-Za-z0-9_.-]+)/[A-Za-z0-9_.-]+#\\d+')
PLACEHOLDER_OWNERS = {'owner', 'o', 'octocat', 'org', 'example'}
OWN_REPO = re.compile('(?<!users/)<login>/[\\w.*-]')
NEGATED = re.compile("\\b(never|do not|don't|must not|blocked?|blocks|refuse[sd]?|forbidden|denied|deny|not allowed)\\b", re.I)
REF_FORMS = (re.compile('(?<![\\w.-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)#(\\d+)'), re.compile('(?<![\\w./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+) (\\d+)\\b'), re.compile('"repo"\\s*:\\s*"([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)"\\s*,\\s*"num"\\s*:\\s*(\\d+)'))
HEX_RUN = re.compile('(?<![0-9A-Za-z])[0-9a-fA-F]{7,40}(?![0-9A-Za-z])')
DATED = re.compile('(?<![\\d.])((?:19|20)\\d{2})(?:-(0[1-9]|1[0-2])(?:-(0[1-9]|[12]\\d|3[01]))?|(0[1-9]|1[0-2])(0[1-9]|[12]\\d|3[01]))(?!\\d)')
NUM_DATE = re.compile('(?<![\\d./])(?:((?:19|20)\\d{2})/(\\d{1,2})/(\\d{1,2})|(\\d{1,2})[/.](\\d{1,2})[/.]((?:19|20)\\d{2}))(?![\\d./])')
BARE_YEAR = re.compile('(?<![\\w.:/-])(?:19[5-9]\\d|20[0-4]\\d)(?![\\w:/-]|\\.\\d)')
TAGGED_YEAR = re.compile('\\b(?:Q[1-4]|H[12]|FY|CY)[-\\s]?(19[5-9]\\d|20[0-4]\\d)(?!\\d)|(?<![\\w.])(19[5-9]\\d|20[0-4]\\d)[-\\s]?(?:Q[1-4]|H[12])\\b')
_MON = '(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\\.?(?![a-z])'
_DAY = '(?:0?[1-9]|[12]\\d|3[01])(?:st|nd|rd|th)?'
MONTH_DAY = re.compile('\\b' + _MON + '[ _-]?' + _DAY + '(?!\\d)')
DAY_MONTH = re.compile('(?<![\\w.])' + _DAY + '[ _-]?(?:of )?' + _MON)
DATE_EXEMPT = ('EXPORT-VERSION',)

def is_test_or_fixture(rel):
    return rel.startswith(('scripts/test_', 'scripts/fixtures/'))

def date_findings(rel, text):
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in DATED.finditer(line):
            year, month, day = (m.group(1), m.group(2) or m.group(4), m.group(3) or m.group(5))
            if year != '2000' and (year, month, day) != (str(2000 - 1), '12', '31'):
                out.append((i, 'dated year other than 2000'))
                break
        for m in NUM_DATE.finditer(line):
            year = m.group(1) or m.group(6)
            parts = {m.group(2), m.group(3)} if m.group(1) else {m.group(4), m.group(5)}
            if year != '2000' and (not (year == str(2000 - 1) and parts == {'12', '31'})):
                out.append((i, 'dated year other than 2000'))
                break
        if any((m.group(0) != '2000' for m in BARE_YEAR.finditer(line))) or any(((m.group(1) or m.group(2)) != '2000' for m in TAGGED_YEAR.finditer(line))):
            out.append((i, 'bare year'))
        if MONTH_DAY.search(line) or DAY_MONTH.search(line):
            out.append((i, 'month-day or day-month date'))
    return out

def item_refs(line):
    return {f'{m.group(1).lower()}#{m.group(2)}' for rx in REF_FORMS for m in rx.finditer(line)}

def sha_hits(line, shas):
    return [t for t in (m.group(0).lower() for m in HEX_RUN.finditer(line)) for sha in shas if sha.startswith(t) or t.startswith(sha)]

def issue_ref_rx(repos):
    return re.compile('\\b(' + '|'.join(map(re.escape, repos)) + ')\\s?#\\d+', re.I) if repos else None

def names_a_real_item(line, repos=None):
    rx = issue_ref_rx(OWNER_REPOS if repos is None else repos)
    if rx and rx.search(line) or LEARNING_ID.search(line) or (IS_EXPORT and OWN_REPO.search(line)):
        return True
    return any((m.group('owner').lower() not in PLACEHOLDER_OWNERS for m in QUALIFIED_REF.finditer(line)))

def load_site_lists(path):
    if not path.is_file():
        return None
    lists = {}
    for line in path.read_text().splitlines():
        m = re.match('^\\s*([A-Z_]+)=(?:\'(.*)\'|"(.*)")\\s*$', line)
        if m:
            value = m.group(2) if m.group(2) is not None else m.group(3)
            lists[m.group(1)] = [t.strip().lower() for t in value.split('|') if t.strip()]
    return lists
SITE = load_site_lists(SITE_FILE)
OWNER_REPOS = (SITE or {}).get('OWNER_REPOS', [])
SOURCE_ONLY = set((SITE or {}).get('SOURCE_ONLY_FILES', []))

def setUpModule():
    if SITE is None:
        print(f'SHIPPED-TREE-NOTE: no site denylist at {SITE_FILE} (set SHIPPED_TREE_DENYLIST_FILE); the name, login, session, private-repo, item, commit and phrase locks are skipped', file=sys.stderr)

def is_posting_instruction(line):
    if POST_VERB.search(line) or MCP_WRITE.search(line) or POST_PROSE.search(line):
        return True
    m = API.search(line)
    if m:
        rest = m.group('rest')
        if API_WRITE_FLAG.search(rest):
            return True
        if API_FIELD.search(rest) and 'graphql' not in rest:
            return True
        if 'graphql' in rest and re.search('\\bmutation\\b', rest):
            return True
    return False

def skill_text(name):
    for p in (REPO / '.claude/skills' / f'{name}.md', REPO / '.claude/skills' / name / 'SKILL.md'):
        if p.exists():
            return (p, p.read_text())
    raise FileNotFoundError(name)

class ShippedTextNamesNoThirdPartyOrOwnItems(unittest.TestCase):

    def _texts(self):
        seen = set()

        def emit(p):
            if p.is_file() and p.suffix in {'.md', '.sh', '.py', '.json', '.conf', ''} and ('__pycache__' not in p.parts) and (p.name not in ('MANIFEST.sha256', 'LICENSE', Path(__file__).name)) and (p.name.lower() not in SOURCE_ONLY) and (not p.name.endswith('.local.conf')) and (p != SITE_FILE.resolve()) and (p not in seen):
                seen.add(p)
                return p
        if IS_EXPORT:
            roots = [REPO]
        else:
            roots = [REPO / 'scripts', REPO / 'bin', REPO / '.claude/hooks']
            for rel in ('docs/README-RUNTIME.md',):
                q = emit(REPO / rel)
                if q:
                    yield (q, q.read_text())
            for name in SHIPPED_AGENTS:
                q = emit(REPO / '.claude/agents' / f'{name}.md')
                yield (q, q.read_text())
            for name in SHIPPED_SKILLS:
                q, t = skill_text(name)
                seen.add(q)
                yield (q, t)
        for root in roots:
            if root.exists():
                for p in sorted(root.rglob('*')):
                    q = emit(p)
                    if q:
                        yield (q, q.read_text(errors='replace'))

    def _site_terms(self, key):
        if SITE is None:
            self.skipTest(f'no site denylist at {SITE_FILE.name} (set SHIPPED_TREE_DENYLIST_FILE): the {key} lock did not run')
        if not SITE.get(key):
            self.skipTest(f'the site denylist has no {key} list: that lock did not run')
        return SITE[key]

    def _hits(self, terms, kind):
        return [f'{p}: {kind} #{k}' for p, t in self._texts() for k, term in enumerate(terms, 1) if term in t.lower()]

    def test_no_operator_personal_name(self):
        terms = self._site_terms('OPERATOR_NAMES') + (SITE.get('OPERATOR_LOGINS', []) if IS_EXPORT else [])
        self.assertEqual(self._hits(terms, 'name'), [], "operator's personal name or login in shipped text")

    def test_no_third_party_logins(self):
        self.assertEqual(self._hits(self._site_terms('THIRD_PARTY_LOGINS'), 'login'), [], 'third-party logins in shipped text')

    def test_no_internal_session_names(self):
        self.assertEqual(self._hits(self._site_terms('SESSION_NAMES'), 'session'), [], 'internal agent or session names in shipped text')

    def test_no_private_repo_names(self):
        self.assertEqual(self._hits(self._site_terms('PRIVATE_REPOS'), 'repo'), [], 'private repository names in shipped text')

    def test_no_listed_item_references(self):
        refs = self._site_terms('ITEM_REFS')
        hits = [f'{p}:{i}: item #{refs.index(r) + 1}' for p, t in self._texts() for i, l in enumerate(t.splitlines(), 1) for r in sorted(item_refs(l)) if r in refs]
        self.assertEqual(hits, [], 'listed item references in shipped text')

    def test_no_listed_commit_shas(self):
        shas = self._site_terms('COMMIT_SHAS')
        hits = [f'{p}:{i}: sha' for p, t in self._texts() for i, l in enumerate(t.splitlines(), 1) if sha_hits(l, shas)]
        self.assertEqual(hits, [], 'listed commit SHAs in shipped text')

    def test_no_listed_phrases(self):
        self.assertEqual(self._hits(self._site_terms('CLAIM_PHRASES'), 'phrase'), [], 'listed phrases in shipped text')

    def test_no_noise_wording(self):
        self.assertEqual(self._hits(self._site_terms('NOISE_PHRASES'), 'noise phrase'), [], 'known noise wording in shipped text')

    def test_tests_use_the_synthetic_year_and_nothing_ships_a_real_date(self):
        hits = []
        for p in sorted(REPO.rglob('*') if IS_EXPORT else (REPO / 'scripts').rglob('*')):
            if not p.is_file() or '.git' in p.parts or '__pycache__' in p.parts or p.name.endswith('.local.conf') or (p.suffix not in {'.md', '.sh', '.py', '.json', '.conf', '.graphql', ''}) or (p.name in ('MANIFEST.sha256', 'LICENSE') + DATE_EXEMPT):
                continue
            rel = str(p.relative_to(REPO))
            if not IS_EXPORT and (not is_test_or_fixture(rel) or p.name.lower() in SOURCE_ONLY):
                continue
            hits += [f'{rel}:{i}: {kind}' for i, kind in date_findings(rel, p.read_text(errors='replace'))]
        self.assertEqual(hits, [], 'real dates in shipped text (tests: use 2000-07-01T06:28:24Z and its neighbours)')

    def test_no_owner_item_references_or_learning_ids(self):
        hits = [f'{p}:{i}: {l.strip()[:80]}' for p, t in self._texts() for i, l in enumerate(t.splitlines(), 1) if names_a_real_item(l)]
        self.assertEqual(hits, [], 'owner-identifying repo#N references or internal learning ids in shipped text')

    def test_filing_ready_record_is_required(self):
        self.assertIn('FILING-READY', (REPO / 'scripts/agent-loop.sh').read_text(), 'the worker prompt must ask for the FILING-READY record')

class PostingScanExamples(unittest.TestCase):

    def test_examples(self):
        yes = ['Act: reply / fix+push / close-with-comment', 'the cap is: post >3 comments to one maintainer per run', "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'", 'gh api repos/o/r/issues/1/comments -f body=x', 'then run `gh pr comment 1 --body-file reply.md`', 'gh pr comment 1 if the maintainer has not replied', 'call mcp issue_write to update the body']
        no = ["gh api graphql -f query='query { viewer { login } }'", 'never run gh pr comment from the loop', 'gh pr view 1 --json state', 'the hook blocks `gh pr merge`', 'pr-timeline o/r 1']
        for line in yes:
            self.assertTrue(is_posting_instruction(line) and (not NEGATED.search(line)), f'should flag: {line}')
        for line in no:
            self.assertFalse(is_posting_instruction(line) and (not NEGATED.search(line)), f'should pass: {line}')

class ItemReferenceScanExamples(unittest.TestCase):

    def test_examples(self):
        yes = ['see acme-labs/widgets#12 for the details', 'tracked in someone/private-notes#3']
        no = ['owner/repo-a#101', 'o/r#9', 'octocat/demo#42', "key = f'{repo}#{number}'", 'pr-timeline owner/repo 101', 'reviewer #3', 'users/<login>/events']
        for line in yes:
            self.assertTrue(names_a_real_item(line, repos=[]), f'should flag: {line}')
        for line in no:
            self.assertFalse(names_a_real_item(line, repos=['widgets']), f'should pass: {line}')
        self.assertTrue(names_a_real_item('widgets#7 is ours', repos=['widgets']))
        self.assertTrue(names_a_real_item('see widgets #7', repos=['widgets']))

class DateScanExamples(unittest.TestCase):

    def test_examples(self):
        import datetime
        t = datetime.date.today()
        later, earlier = (t + datetime.timedelta(days=400), t - datetime.timedelta(days=800))
        mon, month = (t.strftime('%b'), t.strftime('%B'))
        doc_bad = [f'Built {t.isoformat()} against the docs', f'(review {t:%Y%m%d})', f'in {t.year}', f'retro-{t.isoformat()}/', f'items in {t:%Y-%m}', f'a {later.isoformat()} plan', f'since {earlier.isoformat()}', f'the {later.year} roadmap', f'The {mon} {t.day} release', f'after the {mon}-{t.day} sweep', f'on {t.day} {month}', f'the {t.day}-{mon} run', f'{month} {t.day}th', f'{mon}. {t.day}', f'on {t:%Y/%m/%d}', f'by {t:%m/%d/%Y}', f'am {t:%d.%m.%Y}', f'shipped in {t.year}.', f'Q4-{t.year} plan', f'FY{t.year} budget', f'the {t.year}-Q4 review', f'H1 {t.year}']
        doc_ok = ['2000-07-01T06:28:24Z', 'an earlier release', 'port 2050', '9.8.7', 'version 0.1.9', 'the 1999-12-31 boundary', '2000/07/01', 'on 01.07.2000', '31.12.1999', '1/4 of 3/3', 'v1.2.3', 'FY2000']
        for line in doc_bad:
            self.assertTrue(date_findings('docs/x.md', line), f'should flag: {line}')
        for line in doc_ok:
            self.assertFalse(date_findings('docs/x.md', line), f'should pass: {line}')
        for when in (later, earlier, t):
            self.assertTrue(date_findings('scripts/test_x.py', f'"ts": "{when.isoformat()}T02:38:21Z"'), when.year)
        self.assertFalse(date_findings('scripts/test_x.py', '"ts": "1999-12-31T06:58:47Z"'), 'the boundary passes')
        self.assertFalse(date_findings('scripts/test_x.py', '"ts": "2000-07-01T06:28:24Z", today="2000-07-04"'))

class ListedReferenceMatchingExamples(unittest.TestCase):

    def test_examples(self):
        ref = {'acme-labs/widgets#12'}
        self.assertEqual(item_refs('pr-timeline acme-labs/widgets 12 30'), ref)
        self.assertEqual(item_refs('[{"repo":"acme-labs/widgets","num":12}, ...]'), ref)
        self.assertEqual(item_refs('see Acme-Labs/Widgets#12'), ref)
        self.assertEqual(item_refs('pr-timeline <owner/repo> <number> [limit]'), set())
        shas = ['0123abc4567def']
        self.assertTrue(sha_hits('Pushed 0123abc with all fixes', shas))
        self.assertTrue(sha_hits('at 0123ABC4567DEF0', shas))
        self.assertFalse(sha_hits('Pushed <sha> with all fixes', shas))
        self.assertFalse(sha_hits('Pushed 0123abd with all fixes', shas))
        self.assertFalse(sha_hits('id 0123ab', shas))

class SessionStartHookReadsOnlyConfiguredPaths(unittest.TestCase):

    def test_site_check_is_optional_and_no_host_tool_paths(self):
        text = (REPO / '.claude/hooks/session-start-dashboard.sh').read_text()
        self.assertIn('scripts/session-start.local.sh', text, "a site's own checks come from scripts/session-start.local.sh")
        self.assertIn('[ -x "$SITE_CHECK" ]', text, 'the site check runs only when it is present')
        for bad in ('.local/bin',):
            self.assertNotIn(bad, text, f'host path {bad!r} in the session-start hook')

class ShippedAgentsNeverPost(unittest.TestCase):

    def _offending_lines(self, text):
        bad = []
        for i, line in enumerate(text.splitlines(), 1):
            if is_posting_instruction(line) and (not NEGATED.search(line)):
                bad.append(f'{i}: {line.strip()[:120]}')
        return bad

    def test_agents(self):
        for name in SHIPPED_AGENTS:
            p = REPO / '.claude/agents' / f'{name}.md'
            self.assertTrue(p.exists(), p)
            self.assertEqual(self._offending_lines(p.read_text()), [], f'{p.name} instructs a post outside the human-GO path')

    def test_skills(self):
        for name in SHIPPED_SKILLS:
            p, text = skill_text(name)
            self.assertEqual(self._offending_lines(text), [], f'{p} instructs a post outside the human-GO path')

    def test_loop_prompt_does_not_claim_a_hook_it_cannot_see(self):
        src = (REPO / 'scripts/agent-loop.sh').read_text()
        self.assertNotIn('a hook blocks it anyway', src, 'the prompt must not assume the hook is installed')
        self.assertIn('block-gh-write.sh', src, 'the prompt should name the gate and where it is installed')

@unittest.skipUnless(IS_EXPORT, 'export-tree reference lock (the source workspace legitimately has these skills)')
class ExportTreeReferencesOnlyShippedTooling(unittest.TestCase):

    def test_related_sections_point_into_the_tree(self):
        skills, agents = (REPO / '.claude/skills', REPO / '.claude/agents')
        names = {p.name for p in REPO.rglob('*')} | ({p.name for p in skills.iterdir()} if skills.is_dir() else set()) | {p.stem for p in agents.glob('*.md')}
        hits = []
        for p in sorted(REPO.rglob('*.md')):
            section = False
            for i, line in enumerate(p.read_text(errors='replace').splitlines(), 1):
                if line.startswith('## '):
                    section = line.startswith('## Related')
                    continue
                if section:
                    for tok in re.findall('`([^`\\s]+)`', line):
                        base = tok.rstrip('/').split('/')[-1]
                        if re.fullmatch('[a-z0-9]+(-[a-z0-9]+)+|[\\w.-]+\\.(md|sh|py)', base) and base not in names:
                            hits.append(f'{p.relative_to(REPO)}:{i}: {base}')
        self.assertEqual(hits, [], 'Related sections that point outside the tree:\n' + '\n'.join(hits))

    def test_no_listed_unshipped_tools(self):
        if SITE is None or not SITE.get('UNSHIPPED_TOOLS'):
            self.skipTest('no UNSHIPPED_TOOLS list in the site denylist: that lock did not run')
        hits = []
        for p in sorted(REPO.rglob('*')):
            if not p.is_file() or p.suffix not in {'.md', '.sh', '.py', '.json', '.conf', ''} or '__pycache__' in p.parts or (p.name in ('MANIFEST.sha256', 'LICENSE', Path(__file__).name)) or p.name.endswith('.local.conf'):
                continue
            text = p.read_text(errors='replace').lower()
            hits += [f'{p.relative_to(REPO)}: tool #{k}' for k, t in enumerate(SITE['UNSHIPPED_TOOLS'], 1) if t in text]
        self.assertEqual(hits, [], 'listed unshipped tools named in shipped text')

@unittest.skipUnless(IS_EXPORT, 'export-tree hygiene (the source repo tracks dashboard/)')
class ExportTreeHygiene(unittest.TestCase):

    def test_gitignore_covers_state_and_secrets(self):
        gi = (REPO / '.gitignore').read_text()
        for entry in ('dashboard/', 'scratch/', 'scripts/redact-denylist.conf', '.claude/hooks/gh-write-audit.log', '.claude/settings.local.json', '__pycache__/', '*.local.conf'):
            self.assertIn(entry, gi, f'.gitignore must cover {entry}')

    def test_readme_installs_the_hooks(self):
        readme = (REPO / 'README.md').read_text()
        self.assertIn('settings.example.json', readme)
        self.assertRegex(readme, 'cp \\.claude/settings\\.example\\.json \\.claude/settings\\.local\\.json')
if __name__ == '__main__':
    unittest.main()
