#!/usr/bin/env python3
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--wrapper', type=Path, required=True)
    parser.add_argument('--out', type=Path)
    args = parser.parse_args()
    wrapper = args.wrapper.resolve()
    rows = []
    with tempfile.TemporaryDirectory(prefix='gh-ro-offline-review-') as tmp:
        root = Path(tmp)
        bindir = root / 'bin'
        bindir.mkdir()
        fake = bindir / 'gh'
        fake.write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["GH_REVIEW_CAPTURE"],"a") as f:\n    f.write(json.dumps(sys.argv[1:])+"\\n")\n')
        fake.chmod(448)
        capture = root / 'called.jsonl'
        payload = root / 'query.txt'
        payload.write_text('mutation { addComment(input: { subjectId: "fixture", body: "offline fixture" }) { clientMutationId } }\n')
        env = dict(os.environ, PATH=str(bindir) + ':' + os.environ['PATH'], GH_REVIEW_CAPTURE=str(capture))
        cases = [('rest_attached_raw_field', False, ['api', 'repos/example/example/issues/1/comments', '-fbody=offline']), ('rest_attached_typed_field', False, ['api', 'repos/example/example/issues/1/comments', '-Fbody=offline']), ('graphql_query_from_file', False, ['api', 'graphql', '-F', 'query=@' + str(payload)]), ('graphql_query_from_stdin', False, ['api', 'graphql', '-F', 'query=@-']), ('positive_rest_read', True, ['api', 'repos/example/example']), ('positive_inline_graphql_read', True, ['api', 'graphql', '-f', 'query=query { viewer { login } }'])]
        for name, should_forward, argv in cases:
            if capture.exists():
                capture.unlink()
            result = subprocess.run([str(wrapper), *argv], env=env, input=payload.read_text(), capture_output=True, text=True)
            forwarded = capture.exists()
            passed = forwarded and result.returncode == 0 if should_forward else not forwarded and result.returncode != 0
            rows.append(dict(case=name, returncode=result.returncode, fake_gh_invoked=forwarded, expected_forward=should_forward, passed=passed))
    receipt = {'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'wrapper': str(wrapper), 'wrapper_sha256': hashlib.sha256(wrapper.read_bytes()).hexdigest(), 'scope': 'Temporary fake gh only; no network, no external writes. query.txt deliberately has a neutral filename.', 'controls': rows, 'all_passed': all((row['passed'] for row in rows))}
    text = json.dumps(receipt, indent=2) + '\n'
    if args.out:
        args.out.write_text(text)
    print(text, end='')
    return 0 if receipt['all_passed'] else 1
if __name__ == '__main__':
    raise SystemExit(main())
