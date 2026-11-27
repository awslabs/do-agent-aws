#!/usr/bin/env python3
import atexit
import shutil
import importlib.util, json, os, stat, subprocess, tempfile, unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
SCRATCH = REPO / 'scratch'
DASHBOARD = REPO / 'dashboard'
if not DASHBOARD.exists():
    atexit.register(lambda: DASHBOARD.exists() and shutil.rmtree(DASHBOARD, True))
if not SCRATCH.exists():
    SCRATCH.mkdir()
    atexit.register(lambda: SCRATCH.exists() and (not any(SCRATCH.iterdir())) and SCRATCH.rmdir())
FIXTURES = HERE / 'fixtures/gh-ro-review'
GH_RO = HERE / 'gh-ro'
LOOP = HERE / 'agent-loop.sh'

def _fake_gh_env(tmp):
    b = Path(tmp) / 'bin'
    b.mkdir(exist_ok=True)
    rec = Path(tmp) / 'gh.calls'
    (b / 'gh').write_text('#!/usr/bin/env bash\nprintf \'%s\\n\' "$*" >> "$GH_CALLS"\nexit 0\n')
    (b / 'gh').chmod((b / 'gh').stat().st_mode | stat.S_IEXEC)
    env = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", GH_CALLS=str(rec))
    return (env, rec)

def _ro(args, env):
    return subprocess.run([str(GH_RO), *args], env=env, capture_output=True, text=True, cwd=REPO)

class GhRoDeniesWrites(unittest.TestCase):
    WRITES = [['pr', 'comment', '1', '--repo', 'o/r', '--body', 'hi'], ['issue', 'comment', '1', '-R', 'o/r', '--body-file', 'x.md'], ['pr', 'merge', '1', '--repo', 'o/r'], ['pr', 'close', '1', '--repo', 'o/r'], ['pr', 'ready', '1', '--repo', 'o/r'], ['pr', 'review', '1', '--repo', 'o/r', '--approve'], ['issue', 'edit', '1', '-R', 'o/r', '--add-label', 'x'], ['issue', 'close', '1', '-R', 'o/r'], ['api', '-X', 'POST', 'repos/o/r/issues/1/comments', '-f', 'body=hi'], ['api', '--method', 'PATCH', 'repos/o/r/issues/1', '-f', 'state=closed'], ['api', '-XDELETE', 'repos/o/r/issues/comments/9'], ['api', 'repos/o/r/issues/1/comments', '-f', 'body=hi'], ['api', 'repos/o/r/issues/1/comments', '-F', 'body=@x.md'], ['api', 'repos/o/r/issues/1/comments', '--field', 'body=hi'], ['api', 'repos/o/r/issues/1/comments', '--raw-field', 'body=hi'], ['api', 'repos/o/r/issues/1/comments', '--input', 'payload.json'], ['api', 'graphql', '-f', 'query=mutation { addComment(input:{}) { clientMutationId } }'], ['run', 'rerun', '123', '--repo', 'o/r'], ['run', 'cancel', '123', '--repo', 'o/r'], ['workflow', 'run', 'ci.yml', '--repo', 'o/r'], ['auth', 'login'], ['repo', 'delete', 'o/r'], ['label', 'create', 'x', '--repo', 'o/r'], ['pr', 'view', '1', '--repo', 'o/r', '&&', 'gh', 'pr', 'comment', '1'], ['api', '--', '-X', 'POST', 'repos/o/r/issues'], ['api', '--', 'repos/o/r/issues', 'extra'], ['auth', 'status', '--show-token'], ['auth', 'status', '-t'], ['auth', 'status', '--hostname', 'github.com', '--show-token'], ['api', 'repos/o/r/issues/1/comments', '-fbody=offline'], ['api', 'repos/o/r/issues/1/comments', '-Fbody=offline'], ['api', '-Fbody=offline', 'repos/o/r/issues/1/comments'], ['api', 'repos/o/r/issues/1/comments', '--raw-field=body=x'], ['api', 'repos/o/r/issues/1/comments', '-XPOST'], ['api', 'repos/o/r/issues/1', '--method=PATCH'], ['api', 'repos/o/r/issues/1', '-X', 'post'], ['api', 'repos/o/r/rulesets', '--input=-'], ['api', 'repos/o/r/rulesets', '--input', '-'], ['api', 'repos/o/r/issues/1/comments', '-F', 'body=@FILE'], ['api', 'graphql', '-F', 'query=@FILE'], ['api', 'graphql', '-F', 'query=@-'], ['api', 'graphql', '-f', 'query=@-'], ['api', 'graphql', '-Fquery=@FILE'], ['api', 'graphql', '--field=query=@FILE'], ['api', 'graphql', '-F', 'query=@NEUTRAL'], ['api', 'graphql', '-fquery=mutation { addComment(input:{}) { clientMutationId } }'], ['api', 'graphql', '--raw-field=query=mutation { x { id } }'], ['api', 'graphql', '-f', 'query=# looks like a query\nmutation { x { id } }'], ['api', 'graphql', '-f', 'query=subscription { x { id } }'], ['api', 'graphql', '-F', 'owner=@FILE', '-f', 'query=query { viewer { login } }'], ['api', 'graphql', '--input', 'FILE'], ['api', 'graphql'], ['api', 'repos/o/r', '-H', 'X-HTTP-Method-Override: DELETE'], ['api', '--bogus-flag', 'repos/o/r']]

    def test_every_write_form_is_rejected_before_gh_runs(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            env, rec = _fake_gh_env(tmp)
            mutation = 'mutation { addComment(input: { subjectId: "fixture", body: "offline" }) { clientMutationId } }\n'
            f1 = Path(tmp) / 'query.txt'
            f1.write_text(mutation)
            f2 = Path(tmp) / 'neutral.graphql'
            f2.write_text(mutation)
            for w0 in self.WRITES:
                w = [a.replace('@FILE', f'@{f1}').replace('@NEUTRAL', f'@{f2}').replace('FILE', str(f1)) for a in w0]
                r = subprocess.run([str(GH_RO), *w], env=env, input=mutation, capture_output=True, text=True, cwd=REPO)
                self.assertNotEqual(r.returncode, 0, f'ACCEPTED write form: {w}\n{r.stdout}{r.stderr}')
                self.assertIn('gh-ro', r.stderr + r.stdout, f'no gh-ro denial message for {w}')
            self.assertFalse(rec.exists(), f"gh WAS invoked for a write form: {(rec.read_text() if rec.exists() else '')}")

class GhRoAllowsReads(unittest.TestCase):
    READS = [['pr', 'view', '1', '--repo', 'o/r', '--json', 'state,mergeStateStatus'], ['pr', 'checks', '1', '--repo', 'o/r'], ['pr', 'diff', '1', '--repo', 'o/r'], ['issue', 'view', '1', '-R', 'o/r', '--comments'], ['run', 'view', '123', '--repo', 'o/r', '--log'], ['run', 'list', '--repo', 'o/r', '--limit', '5'], ['api', 'repos/o/r/pulls/1'], ['api', 'repos/o/r/issues/events', '--paginate'], ['api', 'graphql', '-f', 'query=query { viewer { login } }'], ['search', 'issues', '--repo', 'o/r', 'deadlock', '--limit', '5'], ['search', 'code', 'parse_header', '--repo', 'o/r'], ['auth', 'status'], ['api', '-X', 'GET', 'repos/o/r'], ['api', '-XGET', 'repos/o/r'], ['api', '--method=get', 'repos/o/r'], ['api', 'repos/o/r', '-q', '.full_name'], ['api', 'repos/o/r', '-q.full_name'], ['api', 'repos/o/r', '-H', 'Accept: application/vnd.github+json', '-i'], ['api', 'repos/o/r/issues', '--paginate', '--slurp', '--cache', '1h'], ['api', 'repos/o/r', '-t', '{{.full_name}}'], ['api', 'graphql', '-fquery=query { viewer { login } }'], ['api', 'graphql', '-F', 'query={ viewer { login } }'], ['api', 'graphql', '--field=query=query { viewer { login } }'], ['api', 'graphql', '-F', 'owner=o', '-F', 'name=r', '-f', 'query=query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){ id } }'], ['api', 'graphql', '-f', 'query=query { search(query:"mutation", type:ISSUE, first:1){ issueCount } }']]

    def test_reads_pass_through_to_gh_unchanged(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            env, rec = _fake_gh_env(tmp)
            for rd in self.READS:
                r = _ro(rd, env)
                self.assertEqual(r.returncode, 0, f'REJECTED read form: {rd}\n{r.stderr}')
            calls = rec.read_text().splitlines()
            self.assertEqual(len(calls), len(self.READS), 'each allowed read must invoke gh exactly once')
            self.assertEqual(calls[0], ' '.join(self.READS[0]), 'argv must pass through unchanged')

class LaunchPathIsBounded(unittest.TestCase):

    def test_worker_allowlist_has_wrapper_and_no_broad_gh(self):
        src = LOOP.read_text()
        self.assertIn('--allowedTools', src, 'worker launch has no --allowedTools (reads get denied headless)')
        self.assertIn('Bash(scripts/gh-ro:*)', src, 'worker allowlist must include the bounded wrapper')
        self.assertIn('Bash(scripts/redact-scan.sh:*)', src, 'the worker needs the redact gate (a read-only script)')
        for broad in ('Bash(gh:*)', 'Bash(gh *)', 'Bash(gh api', 'Bash(gh:', 'bypassPermissions', 'dangerously-skip-permissions'):
            self.assertNotIn(broad, src, f'broad/unsafe permission present in launch path: {broad}')
        import re as _re
        self.assertFalse(_re.search('"(Edit|Write)"', src), 'bare Edit/Write entries give the worker unscoped file writes')
        for scoped in ('Edit(scratch/**)', 'Write(scratch/**)', 'Edit(dashboard/**)', 'Write(dashboard/**)'):
            self.assertIn(scoped, src, f'missing scoped file permission {scoped}')
        self.assertIn('--disallowedTools', src, 'worker launch has no --disallowedTools deny list')
        for denied in ('Edit(scripts/**)', 'Write(scripts/**)', 'Edit(bin/**)', 'Write(bin/**)', 'Edit(.claude/**)', 'Write(.claude/**)', 'Edit(.claude-plugin/**)', 'Write(.claude-plugin/**)', 'Edit(.git/**)', 'Write(.git/**)'):
            self.assertIn(denied, src, f'missing deny rule {denied}')
        launch = _re.search('claude -p .*?--output-format json', src, _re.S)
        self.assertIsNotNone(launch, 'cannot find the claude -p launch line')
        launch = launch.group(0)
        self.assertIn('--permission-mode default', launch, 'the LAUNCH LINE must run in default mode (deny what is not allowed)')
        self.assertIn('--disallowedTools "${WORKER_DENIED_TOOLS[@]}"', launch, 'the launch line must pass the deny list')
        self.assertIn('--allowedTools "${WORKER_ALLOWED_TOOLS[@]}"', launch, 'the launch line must pass the allow list')
        self.assertNotIn('acceptEdits', src, 'acceptEdits auto-accepts edits outside the allow rules')
        self.assertNotIn('Bash(git fetch:*)', src, 'git fetch admits --upload-pack=<cmd>; the worker reads GitHub via gh-ro')
        self.assertIn('export PATH="$PWD/bin:$PATH"', src, 'bin/ (pr-timeline) must be on the worker PATH')

    def test_worker_launch_takes_the_site_environment(self):
        src = LOOP.read_text()
        self.assertIn('noise hook', src, "the prompt's hard rule about the noise hook is expected to stay")
        self.assertIn('env $LOOP_ENV claude -p', src, "the headless worker launch must apply the site's LOOP_ENV")
        self.assertRegex(src, 'LOOP_ENV=\\$\\( \\[ -f \\"\\$SITE_FILE\\" \\] && sed -n \'s/\\^LOOP_ENV=', 'LOOP_ENV must come from the site file')

def _load_pick():
    import sys
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('loop_pick', HERE / 'loop_pick.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

def _row(repo, n, **kw):
    r = {'repo': repo, 'number': n, 'title': f't{n}', 'state': 'OPEN', 'we_owe': False, 'needs_attention': False, 'bucket': None, 'attn_reasons': [], 'updated': '2000-03-14'}
    r.update(kw)
    return r

class DeterministicPicker(unittest.TestCase):

    def setUp(self):
        self.m = _load_pick()

    def test_we_owe_first_then_A_before_D_regardless_of_recency(self):
        state = {'items': [_row('o/r', 1, needs_attention=True, bucket='D-conflict', updated='2000-03-27'), _row('o/r', 2, needs_attention=True, bucket='A-approved-stuck', updated='2000-03-12'), _row('o/r', 3, we_owe=True, updated='2000-03-19'), _row('o/r', 4, needs_attention=True, bucket='C-red-ci', updated='2000-03-25')]}
        order = [r['number'] for r in self.m.pick(state, [], today='2000-03-28')]
        self.assertEqual(order, [3, 2, 4, 1], 'expected we_owe, then A-approved-stuck, then C, then D')

    def test_needs_human_within_ttl_is_skipped_but_movement_unbenches(self):
        state = {'items': [_row('o/r', 1, we_owe=True, updated='2000-03-01'), _row('o/r', 2, we_owe=True, updated='2000-04-09')]}
        log = [json.dumps({'ts': '2000-04-06T09:06:19Z', 'repo': 'o/r', 'number': 1, 'outcome': 'needs-human'}), json.dumps({'ts': '2000-04-06T09:06:19Z', 'repo': 'o/r', 'number': 2, 'outcome': 'needs-human'})]
        picked = [r['number'] for r in self.m.pick(state, log, today='2000-04-10')]
        self.assertEqual(picked, [2], '#1 benched (no movement); #2 moved after bench -> actionable again')

    def test_failed_twice_within_ttl_is_skipped(self):
        state = {'items': [_row('o/r', 1, we_owe=True)]}
        log = [json.dumps({'ts': '2000-04-08T19:07:35Z', 'repo': 'o/r', 'number': 1, 'outcome': 'failed'})] * 2
        self.assertEqual(self.m.pick(state, log, today='2000-04-10'), [])

    def test_staged_is_a_bench_outcome_until_ttl_or_movement(self):
        state = {'items': [_row('o/r', 1, we_owe=True, updated='2000-05-02'), _row('o/r', 2, we_owe=True, updated='2000-05-07')]}
        log = [json.dumps({'ts': '2000-05-05T12:37:48Z', 'repo': 'o/r', 'number': 1, 'outcome': 'staged'}), json.dumps({'ts': '2000-05-05T12:37:48Z', 'repo': 'o/r', 'number': 2, 'outcome': 'staged'})]
        picked = [r['number'] for r in self.m.pick(state, log, today='2000-05-08')]
        self.assertEqual(picked, [2], '#1 staged + no movement -> benched; #2 moved after staging -> actionable')
        self.assertEqual([r['number'] for r in self.m.pick(state, log, today='2000-05-19')], [2, 1])

    def test_replied_item_is_watch_benched_until_someone_else_speaks(self):
        state = {'items': [_row('o/r', 1, needs_attention=True, bucket='B-changes-requested', updated='2000-06-13', last_them={'t': '2000-06-11T02:19:02Z', 'who': 'rev'}), _row('o/r', 2, needs_attention=True, bucket='B-changes-requested', updated='2000-06-14', last_them={'t': '2000-06-14T21:53:22Z', 'who': 'rev'}), _row('o/r', 3, we_owe=True, updated='2000-06-14', last_them={'t': '2000-06-14T21:53:22Z', 'who': 'rev'})]}
        log = [json.dumps({'ts': '2000-06-13T06:27:22Z', 'repo': 'o/r', 'number': n, 'outcome': o}) for n, o in ((1, 'replied'), (2, 'fixed'), (3, 'replied'))]
        picked = [r['number'] for r in self.m.pick(state, log, today='2000-06-14')]
        self.assertEqual(picked, [3, 2], '#1: only our own movement -> watch-benched; #2: reviewer spoke after the row; #3: we_owe again')
        self.assertEqual([r['number'] for r in self.m.pick(state, log, today='2000-06-24')], [3, 2, 1], 'watch bench expires like staged')

    def test_row_carries_the_fields_the_prompt_needs(self):
        state = {'items': [_row('o/r', 9, needs_attention=True, bucket='A-approved-stuck', attn_reasons=['APPROVED but unmergeable'], updated='2000-03-12')]}
        r = self.m.pick(state, [], today='2000-03-28')[0]
        line = self.m.format_line(r)
        self.assertTrue(line.startswith('o/r#9\t[A-approved-stuck]'), line)
        self.assertIn('APPROVED but unmergeable', line)

class PromptCarriesExactItem(unittest.TestCase):

    def test_print_prompt_pins_the_picked_item(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            st = Path(tmp) / 'state.json'
            lg = Path(tmp) / 'loop-log.jsonl'
            st.write_text(json.dumps({'items': [_row('octocat/demo', 42, needs_attention=True, bucket='A-approved-stuck', attn_reasons=['APPROVED but unmergeable — rebase to land'], updated='2000-03-12'), _row('octocat/demo', 7, needs_attention=True, bucket='D-conflict', updated='2000-03-28')]}))
            lg.write_text('')
            env = dict(os.environ, LOOP_STATE=str(st), LOOP_LOG=str(lg))
            r = subprocess.run([str(LOOP), '--print-prompt'], env=env, capture_output=True, text=True, cwd=REPO)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('octocat/demo#42', r.stdout, 'prompt must name the exact picked item')
            self.assertNotIn('octocat/demo#7', r.stdout.split('Work exactly')[-1][:400] if 'Work exactly' in r.stdout else '', 'prompt must not offer the runner-up')
            self.assertIn('A-approved-stuck', r.stdout, 'prompt must carry A-approved-stuck handling')
            self.assertRegex(r.stdout, '(?i)do not pick|exactly this item', 'prompt must forbid re-picking')

def _load_check():
    import sys
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('gh_ro_api_check', HERE / 'gh_ro_api_check.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m

class ApiGrammarChecker(unittest.TestCase):

    def setUp(self):
        self.m = _load_check()

    def deny(self, argv, why_contains):
        ok, reason = self.m.check_api_args(argv)
        self.assertFalse(ok, f'ALLOWED: {argv}')
        self.assertIn(why_contains, reason, f'{argv} -> {reason}')

    def allow(self, argv):
        ok, reason = self.m.check_api_args(argv)
        self.assertTrue(ok, f'DENIED: {argv} -> {reason}')

    def test_attached_short_forms_are_normalized(self):
        self.deny(['repos/o/r', '-fbody=x'], 'field')
        self.deny(['repos/o/r', '-Fbody=x'], 'field')
        self.deny(['repos/o/r', '-XPOST'], 'method')

    def test_file_and_stdin_documents_are_refused_for_being_uninspected_not_for_their_name(self):
        ok, reason = self.m.check_api_args(['graphql', '-F', 'query=@/x/mutation.graphql'])
        self.assertFalse(ok)
        self.assertRegex(reason, '(?i)file|stdin')
        self.assertNotIn('mutation', reason.split('@')[0])
        self.deny(['graphql', '-F', 'query=@/x/neutral.txt'], 'file')
        self.deny(['graphql', '-F', 'query=@-'], 'stdin')
        self.deny(['graphql', '-f', 'query=@-'], 'stdin')

    def test_only_validated_literal_read_documents_pass(self):
        self.allow(['graphql', '-f', 'query=query { viewer { login } }'])
        self.allow(['graphql', '-F', 'query={ viewer { login } }'])
        self.allow(['graphql', '-f', 'query=query { search(query:"mutation", type:ISSUE, first:1){ issueCount } }'])
        self.allow(['graphql', '-f', 'query=# a comment mentioning mutation\nquery { viewer { login } }'])
        self.deny(['graphql', '-f', 'query=mutation { x { id } }'], 'mutation')
        self.deny(['graphql', '-f', 'query=# hidden\nmutation { x { id } }'], 'mutation')
        self.deny(['graphql', '-f', 'query=subscription { x { id } }'], 'subscription')
        self.deny(['graphql', '-f', 'query='], 'query')
        self.deny(['graphql'], 'query')

    def test_explicit_get_is_the_only_method_allowed(self):
        self.allow(['-X', 'GET', 'repos/o/r'])
        self.allow(['--method=get', 'repos/o/r'])
        self.allow(['-XGET', 'repos/o/r'])
        self.deny(['--method', 'PATCH', 'repos/o/r'], 'method')
        self.deny(['-X', 'delete', 'repos/o/r'], 'method')

    def test_unknown_flags_fail_closed_and_double_dash_ends_flags(self):
        self.deny(['--bogus', 'repos/o/r'], 'unknown')
        self.allow(['--', 'repos/o/r'])
        self.deny(['repos/o/r', '--', '-not-a-flag'], 'exactly one endpoint')
        self.deny(['--', '-X', 'POST', 'repos/o/r/issues'], 'exactly one endpoint')

class BlockStringLexerEdge(unittest.TestCase):
    DOC = FIXTURES / 'block-string-offline-document.graphql'

    def setUp(self):
        self.m = _load_check()

    def test_reviewer_exact_document_with_selected_mutation_is_refused(self):
        doc = self.DOC.read_text().rstrip('\n')
        self.assertIn('"""', doc)
        self.assertIn('mutation M', doc)
        ok, reason = self.m.check_api_args(['graphql', '-f', 'query=' + doc, '-f', 'operationName=M'])
        self.assertFalse(ok, 'the selected-mutation document must be refused')
        self.assertRegex(reason, '(?i)block string|mutation')
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            env, rec = _fake_gh_env(tmp)
            r = _ro(['api', 'graphql', '-f', 'query=' + doc, '-f', 'operationName=M'], env)
            self.assertNotEqual(r.returncode, 0)
            self.assertFalse(rec.exists(), 'forwarded to gh')

    def test_any_block_string_is_unsupported_even_in_a_benign_read(self):
        ok, reason = self.m.check_api_args(['graphql', '-f', 'query=query { search(query:"""abc""", type:REPOSITORY) { repositoryCount } }'])
        self.assertFalse(ok)
        self.assertIn('block string', reason.lower())

    def test_multi_operation_with_a_mutation_is_refused_whatever_operationName_selects(self):
        doc = 'query Q { viewer { login } } mutation M { addComment(input:{}) { clientMutationId } }'
        for sel in ('Q', 'M'):
            ok, reason = self.m.check_api_args(['graphql', '-f', 'query=' + doc, '-f', f'operationName={sel}'])
            self.assertFalse(ok, f'operationName={sel} allowed a document that defines a mutation')
            self.assertIn('mutation', reason)

    def test_multi_query_document_with_operationName_is_a_read(self):
        doc = 'query A { viewer { login } } query B { viewer { id } }'
        ok, reason = self.m.check_api_args(['graphql', '-f', 'query=' + doc, '-f', 'operationName=B'])
        self.assertTrue(ok, reason)

    def test_fragment_first_document_is_a_read(self):
        doc = 'fragment F on Repository { id } query Q { repository(owner:"o", name:"r") { ...F } }'
        ok, reason = self.m.check_api_args(['graphql', '-f', 'query=' + doc])
        self.assertTrue(ok, reason)

    def test_escaped_quote_in_a_normal_string_containing_the_word_mutation_is_a_read(self):
        doc = 'query { search(query:"a \\" mutation \\" b", type:ISSUE, first:1) { issueCount } }'
        ok, reason = self.m.check_api_args(['graphql', '-f', 'query=' + doc])
        self.assertTrue(ok, reason)

    def test_unterminated_string_and_sdl_fail_closed(self):
        ok, _ = self.m.check_api_args(['graphql', '-f', 'query=query { s(q:"abc) { id } } mutation M { x }'])
        self.assertFalse(ok)
        ok, _ = self.m.check_api_args(['graphql', '-f', 'query=type X { id: ID }'])
        self.assertFalse(ok)
        ok, _ = self.m.check_api_args(['graphql', '-f', 'query=fragment F on X { id }'])
        self.assertFalse(ok, 'fragment-only document has no operation')

    def test_no_regex_full_validation_claim(self):
        src = (HERE / 'gh_ro_api_check.py').read_text()
        self.assertNotIn('_BLOCK_STR', src, 'block strings must be lexed/rejected, not regex-stripped')
        import ast
        doc = ' '.join((ast.get_docstring(n) or '' for n in ast.walk(ast.parse(src)) if isinstance(n, (ast.Module, ast.FunctionDef, ast.ClassDef))))
        if 'SCOPE' in doc:
            self.assertRegex(doc, '(?i)not a full graphql validator|claims no full validation', 'a stated scope must say it is partial')

class ReviewerReproducer(unittest.TestCase):

    def test_reviewer_harness_all_passed(self):
        harness = FIXTURES / 'verify_gh_ro_boundary.py'
        self.assertTrue(harness.exists(), 'reviewer reproducer missing from scripts/fixtures/gh-ro-review')
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            out = Path(tmp) / 'after.json'
            r = subprocess.run(['python3', str(harness), '--wrapper', str(GH_RO), '--out', str(out)], capture_output=True, text=True, cwd=REPO)
            res = json.loads(out.read_text()) if out.exists() else {}
            self.assertTrue(res.get('all_passed'), f"reviewer controls: {[c for c in res.get('controls', []) if not c.get('passed')]}")
            self.assertEqual(r.returncode, 0)
if __name__ == '__main__':
    unittest.main(verbosity=2)
