#!/usr/bin/env bash
set -uo pipefail

payload="$(cat)"
extract() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -r "$1 // empty" 2>/dev/null
  else
    printf '%s' "$payload" | python3 -I -c '
import sys, json
d = json.load(sys.stdin)
for k in sys.argv[1].lstrip(".").split("."):
    d = d.get(k, {}) if isinstance(d, dict) else {}
print(d if isinstance(d, str) else "")' "$1" 2>/dev/null
  fi
}
tool_name="$(extract '.tool_name')"
cmd="$(extract '.tool_input.command')"
AUDIT_LOG="${GH_WRITE_AUDIT_LOG:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/dashboard/gh-write-audit.log}"

block() {
  printf 'BLOCKED by block-gh-write hook: %s\n' "$1" >&2
  printf 'Outward GitHub writes are operator-gated. Stage the text under scratch/ with a FILING-READY record and stop;\n' >&2
  printf 'a human posts it. Only `gh pr|issue comment` and `gh issue|pr create` pass, and only with\n' >&2
  printf 'GH_WRITE_OPERATOR_OK="<the operator'"'"'s words>" as a prefix (audited). merge/close/review/edit/delete never pass.\n' >&2
  exit 2
}

operator_ok() {
  local tok=""
  tok="$(printf '%s' "${cmd:-}" \
    | grep -oE 'GH_WRITE_OPERATOR_OK=("[^"]*"|'"'"'[^'"'"']*'"'"'|[^[:space:]]+)' \
    | head -1 | sed -e 's/^GH_WRITE_OPERATOR_OK=//' -e 's/^["'"'"']//' -e 's/["'"'"']$//')"
  [ -n "$tok" ] || return 1
  mkdir -p "$(dirname "$AUDIT_LOG")" 2>/dev/null
  if ! printf '%s\tverb=%s\treason=%s\tcmd=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$tok" "${cmd:-}" >> "$AUDIT_LOG" 2>/dev/null; then
    printf 'operator token present but the audit line could not be written to %s — no audit, no permission\n' "$AUDIT_LOG" >&2
    return 1
  fi
  printf 'ALLOWED by operator token (%s): %s — logged to %s\n' "$1" "$tok" "$AUDIT_LOG" >&2
  return 0
}

case "$tool_name" in
  mcp__*[Gg]it[Hh]ub*)
    short="${tool_name##*__}"
    case "$short" in
      get_*|list_*|search_*|*_read) exit 0 ;;
      *) block "GitHub MCP write tool '$tool_name' (only get_*/list_*/search_*/*_read tools are reads)" ;;
    esac ;;
esac

[ "$tool_name" = "Bash" ] && [ -n "$cmd" ] || exit 0

CLASSIFIER=$(cat <<'PY'
import re, shlex, sys
from os.path import basename
raw = sys.stdin.read()

def strip_quoted_heredocs(s):
    pat = re.compile('<<-?\\s*([\\x27\\x22])([A-Za-z_][A-Za-z0-9_]*)\\1')
    while True:
        m = pat.search(s)
        if not m:
            return s
        after = s[m.end():]
        end = re.search('(?m)^[ \\t]*' + re.escape(m.group(2)) + '[ \\t]*$', after)
        s = s[:m.start()] + ' ' + (after[end.end():] if end else ' ')
SEPS = {';', ';;', '&&', '||', '|', '|&', '&', '(', ')', '{', '}'}
DROP = {'sudo', 'doas', 'env', 'command', 'exec', 'nohup', 'time', 'builtin', 'stdbuf', 'unbuffer', 'chronic', 'xargs', 'watch', 'parallel'}
SHELLS = {'bash', 'sh', 'zsh', 'dash', 'ksh'}
READ_OK = {'view', 'list', 'download', 'clone', 'status', 'get', 'diff', 'check', 'help', '--help', '-h'}
RESOURCE = {'repo', 'release', 'gist', 'label', 'secret', 'variable', 'ssh-key', 'gpg-key', 'project', 'ruleset', 'cache', 'codespace', 'org'}
PR_ISSUE_READS = {'view', 'list', 'status', 'diff', 'checks', 'checkout', 'help', '--help', '-h'}
GH_SUBS = {'pr', 'issue', 'repo', 'api', 'release', 'gist', 'label', 'run', 'workflow', 'auth', 'secret', 'variable', 'ssh-key', 'gpg-key', 'project', 'ruleset', 'cache', 'codespace', 'org', 'extension', 'search'}

class Word(str):
    marked = ''

def mark_dollars(s):
    out, q, i = ([], None, 0)
    while i < len(s):
        c = s[i]
        if q == "'":
            q = None if c == "'" else q
        elif c == '\\' and i + 1 < len(s):
            out.append(s[i:i + 2])
            i += 2
            continue
        elif c == '"':
            q = None if q == '"' else '"'
        elif q is None and c == "'":
            q = "'"
        elif c == '$':
            c = '\x00'
        out.append(c)
        i += 1
    return ''.join(out)

def lit(v):
    return getattr(v, 'marked', v) or v

def tokenize(s):
    lex = shlex.shlex(mark_dollars(s), posix=True, punctuation_chars=True)
    lex.whitespace_split = True
    lex.commenters = ''
    out = []
    for t in lex:
        w = Word(t.replace('\x00', '$'))
        w.marked = t
        out.append(w)
    return out

def simple_commands(tokens):
    cur = []
    for t in tokens:
        if t in SEPS:
            if cur:
                yield cur
            cur = []
        else:
            cur.append(t)
    if cur:
        yield cur

def classify_api(rest):
    method = None
    has_field = False
    has_input = False
    endpoint = None
    vals = []
    takes_val = {'-H', '--header', '-q', '--jq', '-t', '--template', '--hostname', '-p', '--preview', '--cache'}
    i = 0
    while i < len(rest):
        t = rest[i]
        if t == '--':
            i += 1
            continue
        if t in ('-X', '--method'):
            method = rest[i + 1] if i + 1 < len(rest) else '?'
            i += 2
            continue
        m = re.match('^(?:-X|--method=)(.+)$', t)
        if m:
            method = m.group(1)
            i += 1
            continue
        if t in ('-f', '-F', '--field', '--raw-field') or re.match('^-i+[fF]$', t):
            has_field = True
            vals.append(rest[i + 1] if i + 1 < len(rest) else '')
            i += 2
            continue
        m = re.match('^(?:--field=|--raw-field=|-i*[fF]=?)(.*)$', lit(t))
        if m:
            has_field = True
            vals.append(m.group(1))
            i += 1
            continue
        if t == '--input' or t.startswith('--input='):
            has_input = True
            i += 1 if '=' in t else 2
            continue
        if t in takes_val:
            i += 2
            continue
        if t.startswith('-'):
            i += 1
            continue
        if endpoint is None:
            endpoint = t
        i += 1
    if has_input:
        return ('BLOCK', 'gh api --input sends a request body (a write)')
    if method is not None and method.strip().upper() != 'GET':
        return ('BLOCK', f'gh api with method {method} (only GET is a read)')
    if endpoint is not None and endpoint.strip('/').lower() == 'graphql':
        for v in vals:
            key, sep, val = lit(v).partition('=')
            if not sep or not re.fullmatch('[A-Za-z_][A-Za-z0-9_]*(?:\\[[A-Za-z0-9_]*\\])*', key):
                return ('BLOCK', 'GraphQL field name is not literal text in the command (fail closed)')
            if key == 'query' and (not val.strip() or val.startswith('@') or '\x00' in val or ('__SUBST__' in val)):
                return ('BLOCK', 'GraphQL query from a file or a shell expansion: only a literal document can be checked (fail closed)')
        if any((re.search('\\bmutation\\b', lit(v)) for v in vals)):
            return ('BLOCK', 'GraphQL mutation document')
        return ('ALLOW', '')
    if has_field:
        return ('BLOCK', 'gh api with -f/-F/--field/--raw-field on a REST endpoint (gh turns the request into a POST)')
    return ('ALLOW', '')

def classify_gh(a):
    if not a:
        return ('ALLOW', '')
    sub, rest = (a[0], a[1:])
    verb = rest[0] if rest else ''
    if sub in ('pr', 'issue'):
        if verb in ('comment', 'create'):
            return ('TOKEN', f'{sub} {verb}')
        if verb in PR_ISSUE_READS:
            return ('ALLOW', '')
        return ('BLOCK', f"gh {sub} {verb or '?'} is an outward write")
    if sub == 'api':
        return classify_api(rest)
    if sub == 'auth':
        if verb == 'status' and len(rest) == 1:
            return ('ALLOW', '')
        return ('BLOCK', f"gh auth {verb or '?'} (prints the token or changes credentials)")
    if sub == 'run':
        return ('ALLOW', '') if verb in ('view', 'list', 'download', 'watch', 'help', '--help') else ('BLOCK', f"gh run {verb or '?'}")
    if sub == 'workflow':
        return ('ALLOW', '') if verb in ('view', 'list', 'help', '--help') else ('BLOCK', f"gh workflow {verb or '?'}")
    if sub == 'extension':
        return ('BLOCK', f"gh extension {verb or '?'} (installs or runs code)") if verb in ('install', 'upgrade', 'remove', 'exec') else ('ALLOW', '')
    if sub in RESOURCE:
        if verb in READ_OK or (sub == 'repo' and verb == 'set-default'):
            return ('ALLOW', '')
        return ('BLOCK', f"gh {sub} {verb or '?'} is an outward write")
    if sub in ('search', 'browse', 'status', 'help', 'completion', 'version', '--version', '--help', '-h', 'alias', 'config', 'attestation'):
        return ('ALLOW', '')
    return ('BLOCK', f'gh {sub}: unknown subcommand, treated as a write (fail closed)')

def classify_string(s, depth=0):
    if depth > 4:
        return [('BLOCK', 'nesting too deep to classify')]
    s = strip_quoted_heredocs(s)
    inner_results = []
    sub_re = re.compile('\\$\\(([^()]*)\\)|`([^`]*)`')
    for m in sub_re.finditer(s):
        inner_results.extend(classify_string(m.group(1) if m.group(1) is not None else m.group(2), depth + 1))
    s = sub_re.sub(' __SUBST__ ', s)
    s = s.replace('$(', ' ; ').replace('`', ' ; ').replace('\n', ' ; ')
    try:
        tokens = tokenize(s)
    except ValueError:
        if re.search('(?:^|[;&|(){}])\\s*(?:\\S+/)?gh\\s+(?:pr|issue|repo|api|release|gist|label|run|workflow|secret|auth|variable)\\b', s):
            return inner_results + [('BLOCK', 'unparseable command (unbalanced quotes) that invokes gh')]
        return inner_results + [('ALLOW', '')]
    results = list(inner_results)
    for simple in simple_commands(tokens):
        i = 0
        while i < len(simple):
            t = simple[i]
            if re.match('^[A-Za-z_][A-Za-z0-9_]*=', t) or t in DROP:
                i += 1
                continue
            if t == 'nice':
                i += 3 if i + 1 < len(simple) and simple[i + 1] == '-n' else 1
                continue
            if t == 'timeout':
                i += 1
                while i < len(simple) and simple[i].startswith('-'):
                    i += 2 if simple[i] in ('-k', '-s', '--kill-after', '--signal') else 1
                i += 1
                continue
            if t in ('-exec', '-execdir', '-ok', '-okdir'):
                i += 1
                continue
            break
        if i >= len(simple):
            continue
        head = basename(simple[i])
        args = simple[i + 1:]
        if (simple[i].startswith('$') or simple[i] == '__SUBST__') and args and (args[0] in GH_SUBS):
            results.append(('BLOCK', f'command word {simple[i]} is a variable or substitution followed by gh usage ({args[0]}): cannot classify, fail closed'))
            continue
        if head in SHELLS:
            for j, t in enumerate(args):
                if t in ('-c', '-lc', '-ec') and j + 1 < len(args):
                    results.extend(classify_string(args[j + 1], depth + 1))
            continue
        if head == 'eval':
            results.extend(classify_string(' '.join(args), depth + 1))
            continue
        if head == 'gh':
            results.append(classify_gh(args))
            continue
        for k, t in enumerate(simple[i + 1:], start=i + 1):
            if basename(t) == 'gh':
                results.append(classify_gh(simple[k + 1:]))
                break
    return results
results = classify_string(raw)
blocks = [r for r in results if r[0] == 'BLOCK']
tokens = [r for r in results if r[0] == 'TOKEN']
if blocks:
    print('BLOCK ' + blocks[0][1])
elif tokens:
    print('TOKEN ' + tokens[0][1])
else:
    print('ALLOW')
PY
)
verdict="$(printf '%s' "$cmd" | python3 -I -c "$CLASSIFIER" 2>/dev/null)" || verdict="BLOCK classifier failed (fail closed)"

case "$verdict" in
  BLOCK*) block "${verdict#BLOCK }" ;;
  TOKEN*) verb="${verdict#TOKEN }"
          operator_ok "$verb" || block "'gh $verb' needs the operator token GH_WRITE_OPERATOR_OK=\"<reason>\"; stage the text for the human GO instead" ;;
  *) exit 0 ;;
esac
