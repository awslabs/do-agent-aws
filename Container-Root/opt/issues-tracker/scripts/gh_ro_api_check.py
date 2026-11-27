#!/usr/bin/env python3
import sys
LONG_VALUE = {'--method': 'method', '--field': 'field', '--raw-field': 'raw-field', '--header': 'header', '--hostname': 'hostname', '--jq': 'jq', '--preview': 'preview', '--template': 'template', '--cache': 'cache', '--input': 'input'}
LONG_BOOL = {'--include', '--paginate', '--silent', '--slurp', '--verbose'}
SHORT_VALUE = {'X': 'method', 'F': 'field', 'f': 'raw-field', 'H': 'header', 'q': 'jq', 'p': 'preview', 't': 'template'}
SHORT_BOOL = {'i'}

class Deny(Exception):
    pass

def parse(argv):
    pos, flags, i = ([], [], 0)
    while i < len(argv):
        tok = argv[i]
        if tok == '--':
            rest = argv[i + 1:]
            if len(rest) != 1 or rest[0].startswith('-'):
                raise Deny('after -- exactly one endpoint is allowed (no flags, no extra positionals)')
            pos.extend(rest)
            break
        if tok.startswith('--'):
            name, eq, val = tok.partition('=')
            if name in LONG_BOOL:
                if eq:
                    raise Deny(f'unknown grammar: boolean flag {name} given a value')
                flags.append((name.lstrip('-'), None))
            elif name in LONG_VALUE:
                if not eq:
                    i += 1
                    if i >= len(argv):
                        raise Deny(f'unknown grammar: {name} needs a value')
                    val = argv[i]
                flags.append((LONG_VALUE[name], val))
            else:
                raise Deny(f'unknown flag {name} (fail-closed)')
        elif tok.startswith('-') and len(tok) > 1:
            j = 1
            while j < len(tok):
                c = tok[j]
                if c in SHORT_BOOL:
                    flags.append((c, None))
                    j += 1
                    continue
                if c in SHORT_VALUE:
                    rest = tok[j + 1:]
                    if rest == '':
                        i += 1
                        if i >= len(argv):
                            raise Deny(f'unknown grammar: -{c} needs a value')
                        rest = argv[i]
                    flags.append((SHORT_VALUE[c], rest))
                    break
                raise Deny(f'unknown flag -{c} (fail-closed)')
        else:
            pos.append(tok)
        i += 1
    return (pos, flags)

def lex_document(doc):
    out, i, n = ([], 0, len(doc))
    while i < n:
        c = doc[i]
        if doc.startswith('"""', i):
            raise Deny('graphql: block strings (""") are not supported by this read gate — use a normal string')
        if c == '"':
            j = i + 1
            while True:
                if j >= n:
                    raise Deny('graphql: unterminated string')
                d = doc[j]
                if d == '\\':
                    j += 2
                    continue
                if d in '\n\r':
                    raise Deny('graphql: unterminated string (newline inside a string)')
                if d == '"':
                    break
                j += 1
            out.append('""')
            i = j + 1
            continue
        if c == '#':
            while i < n and doc[i] not in '\n\r':
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)

def _skip_braces(code, i):
    depth = 0
    while i < len(code):
        if code[i] == '{':
            depth += 1
        elif code[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    raise Deny('graphql: unbalanced braces')

def top_level_definitions(code):
    defs, i, n = ([], 0, len(code))
    while i < n:
        c = code[i]
        if c.isspace() or c == ',':
            i += 1
            continue
        if c == '{':
            defs.append('{')
            i = _skip_braces(code, i)
            continue
        j = i
        while j < n and (code[j].isalnum() or code[j] == '_'):
            j += 1
        if j == i:
            raise Deny(f'graphql: unexpected {c!r} at top level')
        word = code[i:j]
        defs.append(word)
        k = code.find('{', j)
        if k == -1:
            raise Deny(f'graphql: definition {word!r} has no selection set')
        i = _skip_braces(code, k)
    return defs

def literal_read_document(doc):
    if not doc or not doc.strip():
        raise Deny('graphql: empty query document')
    defs = top_level_definitions(lex_document(doc))
    if not defs:
        raise Deny('graphql: empty query document')
    for w in defs:
        if w in ('mutation', 'subscription'):
            raise Deny(f'graphql: document defines a {w} operation — not a read')
        if w not in ('query', 'fragment', '{'):
            raise Deny(f'graphql: unsupported top-level definition {w!r} — this gate accepts query/fragment/anonymous-query documents only')
    if not any((w in ('query', '{') for w in defs)):
        raise Deny('graphql: document has no query operation')
    return True

def check_api_args(argv):
    try:
        pos, flags = parse(argv)
        if not pos:
            raise Deny('no endpoint')
        graphql = pos[0] == 'graphql'
        fields = []
        for name, val in flags:
            if name == 'input':
                raise Deny('--input supplies a request body from a file/stdin — not a read')
            if name == 'method':
                if (val or '').strip().upper() != 'GET':
                    raise Deny(f'method {val!r} is not a read (only GET is allowed)')
            if name == 'header':
                hname = (val or '').split(':', 1)[0].strip().lower()
                if hname in ('x-http-method-override', 'x-method-override'):
                    raise Deny(f'header {hname} overrides the HTTP method')
            if name in ('field', 'raw-field'):
                fields.append((name, val))
        if fields and (not graphql):
            raise Deny('field flags (-f/-F/--field/--raw-field) turn a GET into a POST — not a read')
        if graphql:
            queries = []
            for kind, val in fields:
                key, eq, value = (val or '').partition('=')
                if not eq:
                    raise Deny(f'graphql: malformed {kind} {val!r} (expected key=value)')
                if value.startswith('@'):
                    src = 'stdin' if value == '@-' else 'a file'
                    raise Deny(f'graphql: {key} value is read from {src} ({value}) and would never be inspected — literal documents only')
                if key == 'query':
                    queries.append(value)
            if len(queries) != 1:
                raise Deny('graphql: exactly one literal query field is required')
            literal_read_document(queries[0])
        return (True, 'read')
    except Deny as d:
        return (False, str(d))

def main(argv):
    ok, reason = check_api_args(argv)
    if ok:
        return 0
    sys.stderr.write(f"gh-ro: DENIED — {reason}: gh api {' '.join(argv)}\n")
    return 3
if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
