#!/usr/bin/env python3
import atexit
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
HERE = Path(__file__).resolve().parent
REPO = HERE.parent
HOOK = REPO / '.claude/hooks/block-gh-write.sh'
NOISE = REPO / '.claude/hooks/pretooluse-block-comment-noise.sh'
SCRATCH = REPO / 'scratch'
if not SCRATCH.exists():
    SCRATCH.mkdir()
    atexit.register(lambda: SCRATCH.exists() and (not any(SCRATCH.iterdir())) and SCRATCH.rmdir())
TEST_HOME = tempfile.mkdtemp(prefix='hooktest-home-')
atexit.register(shutil.rmtree, TEST_HOME, True)

def run_hook(hook, tool_name, command=None, extra_env=None, audit=None):
    payload = {'tool_name': tool_name, 'tool_input': {'command': command} if command is not None else {}}
    env = dict(os.environ, HOME=TEST_HOME)
    env.pop('GH_WRITE_OPERATOR_OK', None)
    if audit:
        env['GH_WRITE_AUDIT_LOG'] = str(audit)
    if extra_env:
        env.update(extra_env)
    r = subprocess.run(['bash', str(hook)], input=json.dumps(payload), capture_output=True, text=True, env=env, cwd=REPO)
    return (r.returncode, r.stderr + r.stdout)
BLOCKED_BASH = ['gh pr merge 1 --repo o/r', 'gh pr close 1 --repo o/r', 'gh pr review 1 --approve --repo o/r', 'gh pr comment 1 --repo o/r --body hi', 'gh issue comment 1 -R o/r --body-file x.md', 'gh issue close 1 -R o/r', 'gh issue create --repo o/r --title t --body b', 'gh pr create --fill', 'gh pr edit 1 --add-label x', 'gh issue edit 1 --add-label x', 'gh pr ready 1', 'gh issue reopen 1', 'gh repo delete o/r --yes', 'gh repo edit o/r --visibility public', 'gh release create v1 --notes x', 'gh gist create f.md', 'gh label create bug --repo o/r', 'gh run cancel 1 --repo o/r', 'gh run rerun 1', 'gh workflow run ci.yml', 'gh auth status --show-token', 'gh auth token', 'gh secret set X --body y', 'gh api -X POST repos/o/r/issues', 'gh api -XPOST repos/o/r/issues', 'gh api --method=POST repos/o/r/issues', 'gh api --method POST repos/o/r/issues', 'gh api -X PATCH repos/o/r/issues/1', 'gh api -X DELETE repos/o/r/issues/comments/9', 'gh api repos/o/r/issues/1/comments -F body=x', 'gh api repos/o/r/issues/1/comments -f body=x', 'gh api repos/o/r/issues/1/comments --field body=x', 'gh api repos/o/r/issues/1/comments --raw-field body=x', 'gh api repos/o/r/issues --input payload.json', 'gh api "repos/o/r/issues" -X "POST"', 'gh api -- -X POST repos/o/r/issues', "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'", 'timeout 20 gh pr merge 1', '/usr/bin/gh pr merge 1', 'command gh pr merge 1', "bash -c 'gh pr merge 1'", 'sh -c "gh pr merge 1"', 'env GH_TOKEN=x gh pr merge 1', 'sudo gh pr merge 1', 'nice -n 5 gh pr merge 1', 'nohup gh pr merge 1 &', 'cd /tmp && gh pr merge 1', 'true; gh pr merge 1', 'gh pr view 1 | cat; gh pr comment 1 --body hi', 'echo hi | gh pr comment 1 --body-file -', "eval 'gh pr merge 1'", 'GH_WRITE_OPERATOR_OK=x gh pr merge 1', 'GH_WRITE_OPERATOR_OK=x gh api -X POST repos/o/r/issues/1/comments -f body=hi', 'GH_WRITE_OPERATOR_OK=x gh pr review 1 --approve', 'GH_WRITE_OPERATOR_OK=x gh issue close 1', '$(which gh) pr merge 1', 'G=gh; $G pr merge 1', '`which gh` pr merge 1', '$(command -v gh) issue close 1', 'GHBIN=/usr/bin/gh; $GHBIN api -X POST repos/o/r/issues', '$(echo gh) pr merge 1', '`echo gh` issue close 1', '$(printf gh) api -X POST repos/o/r/issues', '${G} pr merge 1', 'echo $(gh pr merge 1)', 'x=`gh issue close 1`', 'echo "gh pr comment"; GH_WRITE_OPERATOR_OK=x gh pr merge 1', 'GH_WRITE_OPERATOR_OK=x gh pr close 9', 'GH_WRITE_OPERATOR_OK=x gh pr comment 1 -b x && gh pr merge 1', 'GH_WRITE_OPERATOR_OK=x bash -c "gh pr merge 1"']
ALLOWED_BASH = ['gh pr list --repo o/r', 'gh pr view 1 --repo o/r --json state', 'gh issue view 1 -R o/r', 'gh pr checks 1', 'gh api repos/o/r/pulls/1', 'gh api repos/o/r/issues/1/comments?per_page=100', 'gh api -X GET repos/o/r/pulls/1', "gh api graphql -f query='query { viewer { login } }'", 'gh api graphql -f query=\'query($o:String!){ repository(owner:$o,name:"r"){ name } }\' -F o=x', "gh search issues --repo o/r 'x'", 'gh auth status', 'gh run view 1 --log', 'gh repo view o/r', 'scripts/gh-ro pr view 1 --repo o/r', 'pr-timeline o/r 1', 'python3 scripts/gh-dashboard.py --open-only', 'git commit -m "docs: the hook blocks a gh pr merge"', 'echo "never run gh pr comment from the loop"', "cat <<'EOF' > scratch/x.md\nthe forbidden form is: gh pr merge 1\nEOF", "grep -n 'gh pr comment' scratch/notes.md", 'ls -la', 'jq . dashboard/state.json', '$PYTHON scripts/x.py', '$EDITOR notes.md', 'P=python3; $P -m unittest scripts/test_x.py', 'echo $(date) done', '$(echo python3) scripts/x.py', 'V=`date`; echo $V']
MCP_BLOCKED = ['mcp__github__merge_pull_request', 'mcp__plugin_github_github__issue_write', 'mcp__plugin_github_github__pull_request_review_write', 'mcp__plugin_github_github__delete_repository', 'mcp__plugin_github_github__push_files', 'mcp__plugin_github_github__create_pull_request', 'mcp__plugin_github_github__create_or_update_file', 'mcp__github__add_issue_comment', 'mcp__plugin_github_github__sub_issue_write', 'mcp__plugin_github_github__update_pull_request', 'mcp__plugin_github_github__fork_repository', 'mcp__plugin_github_github__request_copilot_review', 'mcp__plugin_github_github__create_branch', 'mcp__plugin_github_github__update_issue_comment']
MCP_ALLOWED = ['mcp__plugin_github_github__get_me', 'mcp__plugin_github_github__list_issues', 'mcp__plugin_github_github__search_issues', 'mcp__plugin_github_github__issue_read', 'mcp__plugin_github_github__pull_request_read', 'mcp__plugin_github_github__get_file_contents', 'mcp__plugin_github_github__list_commits', 'mcp__example__create_item']

class WriteGateBlocksEveryWriteForm(unittest.TestCase):

    def test_hook_exists_and_is_executable(self):
        self.assertTrue(HOOK.is_file(), f'missing {HOOK}')
        self.assertTrue(os.access(HOOK, os.X_OK))

    def test_blocked_bash_forms(self):
        for cmd in BLOCKED_BASH:
            rc, out = run_hook(HOOK, 'Bash', cmd)
            self.assertEqual(rc, 2, f'ALLOWED a write form: {cmd!r}\n{out[:300]}')

    def test_allowed_bash_forms(self):
        for cmd in ALLOWED_BASH:
            rc, out = run_hook(HOOK, 'Bash', cmd)
            self.assertEqual(rc, 0, f'BLOCKED a read or prose: {cmd!r}\n{out[:300]}')

    def test_mcp_github_write_tools_blocked_reads_allowed(self):
        for name in MCP_BLOCKED:
            rc, out = run_hook(HOOK, name)
            self.assertEqual(rc, 2, f'ALLOWED MCP write tool {name}\n{out[:200]}')
        for name in MCP_ALLOWED:
            rc, out = run_hook(HOOK, name)
            self.assertEqual(rc, 0, f'BLOCKED MCP read tool {name}\n{out[:200]}')

    def test_operator_token_admits_only_comment_and_create_and_is_audited(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            audit = Path(tmp) / 'audit.log'
            for cmd in ('GH_WRITE_OPERATOR_OK="operator GO 2000-11-17" gh pr comment 1 --repo o/r --body-file scratch/x.md', "GH_WRITE_OPERATOR_OK='go' gh issue create --repo o/r --title t --body-file scratch/b.md", 'GH_WRITE_OPERATOR_OK=go gh issue comment 1 -R o/r --body hi', 'GH_WRITE_OPERATOR_OK=go gh pr create --repo o/r --title t --body b'):
                rc, out = run_hook(HOOK, 'Bash', cmd, audit=audit)
                self.assertEqual(rc, 0, f'token did not admit {cmd!r}\n{out[:300]}')
            self.assertTrue(audit.exists(), 'operator path must leave an audit line')
            lines = audit.read_text().strip().splitlines()
            self.assertEqual(len(lines), 4)
            self.assertIn('reason=operator GO 2000-11-17', lines[0])
            rc, out = run_hook(HOOK, 'Bash', 'gh pr comment 1 --repo o/r --body hi', extra_env={'GH_WRITE_OPERATOR_OK': 'env go'}, audit=audit)
            self.assertEqual(rc, 2, f'env token admitted a comment\n{out[:200]}')
            rc, out = run_hook(HOOK, 'Bash', 'GH_WRITE_OPERATOR_OK=x gh pr comment 1 -b x', audit=audit)
            self.assertEqual(rc, 0, out[:200])
            self.assertIn('verb=pr comment', audit.read_text().splitlines()[-1])

    def test_token_path_fails_closed_when_the_audit_line_cannot_be_written(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            rc, out = run_hook(HOOK, 'Bash', 'GH_WRITE_OPERATOR_OK=x gh pr comment 1 -b x', audit=Path(tmp))
            self.assertEqual(rc, 2, f'no audit line, yet allowed\n{out[:200]}')
            self.assertIn('audit', out.lower())

class GraphqlQueryMustBeLiteral(unittest.TestCase):

    def test_query_from_a_file_is_refused(self):
        for cmd in ('gh api graphql -F query=@m.graphql', "gh api graphql -F 'query=@m.graphql'", 'gh api graphql --field query=@m.graphql', 'gh api graphql --field=query=@m.graphql', 'gh api graphql -Fquery=@m.graphql', 'gh api graphql -iF query=@m.graphql'):
            rc, out = run_hook(HOOK, 'Bash', cmd)
            self.assertEqual(rc, 2, f'ALLOWED a query read from a file: {cmd!r}\n{out[:300]}')

    def test_query_from_a_variable_is_refused(self):
        for cmd in ('gh api graphql -f query="$Q"', 'gh api graphql -f query=$Q', 'gh api graphql -f query="${Q}"', 'gh api graphql -f query="$(cat m.graphql)"', 'gh api graphql -f query=$(cat m.graphql)', 'gh api graphql -f query="`cat m.graphql`"', 'gh api graphql -F "$K=@m.graphql"'):
            rc, out = run_hook(HOOK, 'Bash', cmd)
            self.assertEqual(rc, 2, f'ALLOWED a query built by the shell: {cmd!r}\n{out[:300]}')

    def test_literal_mutation_is_refused(self):
        cmd = "gh api graphql -f query='mutation { addComment(input:{}) { clientMutationId } }'"
        rc, out = run_hook(HOOK, 'Bash', cmd)
        self.assertEqual(rc, 2, f'ALLOWED a literal mutation: {cmd!r}\n{out[:300]}')

    def test_literal_query_is_allowed(self):
        for cmd in ("gh api graphql -f query='query { viewer { login } }'", 'gh api graphql -f query=\'query($o:String!){ repository(owner:$o,name:"r"){ name } }\' -F o="$O"'):
            rc, out = run_hook(HOOK, 'Bash', cmd)
            self.assertEqual(rc, 0, f'BLOCKED a literal read query: {cmd!r}\n{out[:300]}')

class NoiseHookBlocksTheNoisePattern(unittest.TestCase):
    NO_SITE = {'SHIPPED_TREE_DENYLIST_FILE': '/nonexistent/site.local.conf'}

    def test_signature_bodies_blocked(self):
        for body in ('Nothing has moved here in 21 days; the PR closes soon.', 'This PR gets closed 5 days from now.', 'Closing in 3 days unless there is news.'):
            rc, out = run_hook(NOISE, 'Bash', f'gh pr comment 1 --repo o/r --body "{body}"', extra_env=self.NO_SITE)
            self.assertEqual(rc, 2, f'noise body allowed: {body!r}\n{out[:200]}')

    def test_substantive_body_allowed(self):
        rc, out = run_hook(NOISE, 'Bash', 'gh pr comment 1 --repo o/r --body "Updated the branch; the conflict in transport.py is resolved by keeping both changes."', extra_env=self.NO_SITE)
        self.assertEqual(rc, 0, out[:200])

    def test_site_file_supplies_the_exact_wording(self):
        with tempfile.TemporaryDirectory(dir=SCRATCH) as tmp:
            site = Path(tmp) / 'site.local.conf'
            site.write_text('NOISE_REGEX="zebra-[0-9]+ marker"\n')
            env = {'SHIPPED_TREE_DENYLIST_FILE': str(site)}
            rc, out = run_hook(NOISE, 'Bash', 'gh pr comment 1 --repo o/r --body "a zebra-42 marker"', extra_env=env)
            self.assertEqual(rc, 2, out[:200])
            rc, out = run_hook(NOISE, 'Bash', 'gh pr comment 1 --repo o/r --body "We will close this in 5 days without a reply."', extra_env=env)
            self.assertEqual(rc, 0, 'the site pattern replaces the generic one\n' + out[:200])

class HooksAreWired(unittest.TestCase):

    def _commands(self, cfg):
        out = {}
        for event, groups in cfg.get('hooks', {}).items():
            for g in groups:
                out.setdefault((event, g.get('matcher', '')), []).extend((h['command'] for h in g.get('hooks', [])))
        return out

    def _check(self, cfg, label):
        cmds = self._commands(cfg)
        pre = {m: c for (ev, m), c in cmds.items() if ev == 'PreToolUse'}
        bash_cmds = ' '.join(pre.get('Bash', []))
        self.assertIn('block-gh-write.sh', bash_cmds, f'{label}: write gate not wired for Bash')
        self.assertIn('pretooluse-block-comment-noise.sh', bash_cmds, f'{label}: noise guard not wired for Bash')
        mcp = [c for m, c in pre.items() if re.search('mcp', m)]
        self.assertTrue(mcp and any(('block-gh-write.sh' in x for c in mcp for x in c)), f'{label}: write gate not wired for GitHub MCP tools')
        for c in sum(pre.values(), []):
            self.assertRegex(c, '"\\$\\{CLAUDE_(PROJECT_DIR|PLUGIN_ROOT)\\}', f'{label}: hook path must be quoted: {c}')
            self.assertIn('|| exit 2', c, f'{label}: a missing/broken hook must block, not fail open: {c}')

    def test_hooks_json(self):
        self._check(json.loads((REPO / '.claude/hooks/hooks.json').read_text()), 'hooks.json')

    def test_settings(self):
        p = REPO / '.claude/settings.local.json'
        if not p.exists():
            p = REPO / '.claude/settings.example.json'
        self._check(json.loads(p.read_text()), p.name)
if __name__ == '__main__':
    unittest.main()
