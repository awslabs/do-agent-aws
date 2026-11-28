#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Unit test of the comms UI CONFIG-management path (the second half of the
# COMMS_UI_WRITE_ENABLED write surface): connections (instances) and monitored channels
# are managed from the dashboard as STAGED settings.json diffs - nothing touches the file
# until an explicit human click on that exact diff. Fully OFFLINE: everything runs against
# the engine's credential-free fake adapter and a test-local settings.json; no real
# platform call is ever made and no secret exists anywhere in the test.
#
# Properties proven:
#   1. the pinned engine ships the config surface (scripts/dashboard_config.py)
#   2. gate OFF: the dashboard renders NO config surface and the config module is never
#      even imported into the UI process (sys.modules stays clean)
#   3. adding a connection through the REAL UI widgets STAGES a diff: settings.json is
#      byte-for-byte untouched, and the staged card offers Apply/Discard
#   4. the explicit human click applies it: settings.json carries the new connection,
#      the engine's own loader accepts the file, and the flash states the reload truth
#      (a running scheduler/watcher loads settings at startup - restart required; the
#      engine has no hot-reload path and the UI does not pretend otherwise)
#   5. a channel added with the form's defaults lands with NO reply_policy key - deny
#      comes from the engine loader's own default ('never'), by omission
#   6. a channel added at reply_policy 'staged' is flagged POLICY WIDENING in red on the
#      exact card the human clicks - and still applies nothing until that click
#   7. discard is terminal and kept: the row stays DISCARDED and offers no Apply
#   8. auth env-var indirection: the surface shows the variable NAME and whether it is
#      set - the VALUE of a set variable never renders anywhere on the page
# Uses test-local state directories (/tmp/comms-config-smoke*); does not disturb /wd.

D=/tmp/comms-config-smoke
rm -rf "${D:?}"
mkdir -p ${D}

export COMMS_HOME=${COMMS_HOME:-/opt/comms}
export COMMS_PYTHON=${COMMS_PYTHON:-/opt/comms-venv/bin/python}  # streamlit's own Python 3.12 environment (setup/install-comms.sh)

fail()
{
	echo "Test8 FAILED: $1"
	exit 1
}

# --- preflight: engine + streamlit (installed by setup/install-comms.sh in the image) ---
if [ ! -f "${COMMS_HOME}/scripts/dashboard.py" ] || ! command -v python3 > /dev/null; then
	echo "Test8 skipped: communication engine not installed under ${COMMS_HOME} (run setup/install-comms.sh)"
	exit 0
fi

# --- 1. the pin ships the config surface ---
[ -f "${COMMS_HOME}/scripts/dashboard_config.py" ] \
	|| fail "engine at ${COMMS_HOME} has no scripts/dashboard_config.py - install-comms.sh pin predates config management"
python3 -c "import sys; sys.path.insert(0, '${COMMS_HOME}'); import core.reconfig" \
	|| fail "engine at ${COMMS_HOME} has no core/reconfig.py"
echo "ok 1 - pinned engine ships the config-management surface"

# --- test-local settings: the fake adapter, one composable channel ---
COMMS_SETTINGS=${D}/settings.json
export COMMS_SETTINGS
python3 - << 'EOF' || fail "could not write test-local settings"
import json, os, pathlib
home = os.environ["COMMS_HOME"]
out = pathlib.Path(os.environ["COMMS_SETTINGS"])
out.write_text(json.dumps({
    "engine": {"state_dir": "state", "channels_dir": home + "/channels",
               "store": "state/messages.db", "journal": "state/journal.db",
               "outbox": "state/outbox.db"},
    "instances": [{"name": "team", "adapter": "fake",
                   "channels": [{"id": "fake-demo", "reply_policy": "staged"}]}],
}, indent=2) + "\n")
EOF

# --- 2. gate OFF: no config surface, module never imported ---
COMMS_UI_WRITE_ENABLED=false "${COMMS_PYTHON}" - << 'EOF' || fail "gate-off dashboard grew a config surface"
import os, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from streamlit.testing.v1 import AppTest
at = AppTest.from_file(os.environ["COMMS_HOME"] + "/scripts/dashboard.py",
                       default_timeout=60).run()
assert not at.exception, at.exception
assert "dashboard_config" not in sys.modules, \
    "the config write layer was imported with the gate off"
assert not [b for b in at.button if b.key and b.key.startswith("confapply-")], \
    "a config Apply button rendered with the gate off"
headers = "\n".join(str(h.value) for h in at.header)
assert "connections & monitored channels" not in headers, \
    "the config surface rendered with the gate off"
EOF
echo "ok 2 - gate off: no config surface, config module not imported"

# --- 3..7. the staged-apply cycle through the REAL UI widgets, offline ---
COMMS_UI_WRITE_ENABLED=true "${COMMS_PYTHON}" - << 'EOF' || fail "config cycle (stage -> click -> apply -> discard) failed"
import json, os, sqlite3, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from streamlit.testing.v1 import AppTest
from core.config import load

SETTINGS = os.environ["COMMS_SETTINGS"]
STAGE_DB = os.path.dirname(SETTINGS) + "/state/confstage.db"

def run():
    return AppTest.from_file(os.environ["COMMS_HOME"] + "/scripts/dashboard.py",
                             default_timeout=60).run()

def by_key(widgets, key):
    found = [w for w in widgets if w.key == key]
    assert len(found) == 1, f"widget {key!r}: {len(found)} found"
    return found[0]

def submit(at, form_key):
    found = [b for b in at.button
             if b.key and b.key.startswith(f"FormSubmitter:{form_key}")]
    assert len(found) == 1, f"form {form_key!r} lost its submit"
    return found[0].click().run()

def gate_buttons(at, prefix):
    return [b for b in at.button if b.key and b.key.startswith(prefix)]

def stage_states():
    conn = sqlite3.connect(f"file:{STAGE_DB}?mode=ro", uri=True)
    try:
        return [r[0] for r in conn.execute(
            "SELECT state FROM confstage ORDER BY created_at")]
    finally:
        conn.close()

# 3: add a connection -> STAGED, file untouched
before = open(SETTINGS).read()
at = run()
assert not at.exception, at.exception
by_key(at.text_input, "confaddinst-name").input("alerts")
by_key(at.selectbox, "confaddinst-adapter").select("fake")
at = submit(at, "conf-add-inst")
assert not at.exception, at.exception
assert open(SETTINGS).read() == before, \
    "SUBMITTING A FORM WROTE settings.json - the click gate does not exist"
assert stage_states() == ["STAGED"], stage_states()
assert len(gate_buttons(at, "confapply-")) == 1, "staged diff not at the gate"
print("ok 3 - add-connection staged; settings.json untouched until the click")

# 4: the human click applies; loader accepts; reload truth stated
at = gate_buttons(at, "confapply-")[0].click().run()
assert not at.exception, at.exception
raw = json.loads(open(SETTINGS).read())
assert "alerts" in [i["name"] for i in raw["instances"]], "click did not apply"
load(SETTINGS)                    # the engine's own loader accepts the written file
flashes = "\n".join(str(s.value) for s in at.success)
for word in ("restart", "startup"):
    assert word in flashes, f"the apply flash lost the reload truth ({word!r})"
print("ok 4 - click applied; engine loader accepts; restart-required truth stated")

# 5: a default-policy channel lands with NO reply_policy key (deny by omission)
by_key(at.selectbox, "confaddchan-inst").select("alerts")
by_key(at.text_input, "confaddchan-id").input("C_DEFAULT")
at = submit(at, "conf-add-chan")
assert not at.exception, at.exception
at = gate_buttons(at, "confapply-")[0].click().run()
alerts = next(i for i in json.loads(open(SETTINGS).read())["instances"]
              if i["name"] == "alerts")
ch = next(c for c in alerts["channels"] if c["id"] == "C_DEFAULT")
assert "reply_policy" not in ch, \
    "the form default wrote a policy key - deny must come from the loader, by omission"
cfg = load(SETTINGS)
got = next(c for c in cfg.instance("alerts").channels if c.id == "C_DEFAULT")
assert got.policy() == "never", got.policy()
print("ok 5 - default add-channel denies by omission (loader resolves it to never)")

# 6: a widening is flagged in red on the card, and still waits for the click
before = open(SETTINGS).read()
by_key(at.selectbox, "confaddchan-inst").select("alerts")
by_key(at.text_input, "confaddchan-id").input("C_HOT")
by_key(at.selectbox, "confaddchan-policy").select("staged")
at = submit(at, "conf-add-chan")
errors = "\n".join(str(e.value) for e in at.error)
assert "POLICY WIDENING" in errors, "a promoted policy staged without the loud flag"
assert "C_HOT" in errors, "the flag does not name the widened channel"
assert open(SETTINGS).read() == before, "the widening applied without a click"
at = gate_buttons(at, "confapply-")[0].click().run()
assert "C_HOT" in open(SETTINGS).read(), "the widening click did not apply"
print("ok 6 - widening flagged POLICY WIDENING on its card; applied only by the click")

# 7: discard is terminal and kept
by_key(at.selectbox, "confaddchan-inst").select("alerts")
by_key(at.text_input, "confaddchan-id").input("C_REJECTED")
at = submit(at, "conf-add-chan")
at = gate_buttons(at, "confdiscard-")[0].click().run()
assert not at.exception, at.exception
assert stage_states().count("DISCARDED") == 1, stage_states()
assert not gate_buttons(at, "confapply-"), "a discarded diff still offers Apply"
assert "C_REJECTED" not in open(SETTINGS).read(), "the discarded change was applied"
print("ok 7 - discard terminal; the refusal kept in the stage record")
EOF

# --- 8. env-var indirection: the NAME renders, the VALUE never does ---
export TEST8_PROBE_TOKEN="sekrit-value-77f2"
"${COMMS_PYTHON}" - << 'EOF' || fail "env indirection leaked or lost the reference"
import json, os, sys
sys.path.insert(0, os.environ["COMMS_HOME"])
from streamlit.testing.v1 import AppTest
SETTINGS = os.environ["COMMS_SETTINGS"]
raw = json.loads(open(SETTINGS).read())
raw["instances"][0]["auth"] = {"token": "env:TEST8_PROBE_TOKEN"}
open(SETTINGS, "w").write(json.dumps(raw, indent=2) + "\n")
os.environ["COMMS_UI_WRITE_ENABLED"] = "true"
at = AppTest.from_file(os.environ["COMMS_HOME"] + "/scripts/dashboard.py",
                       default_timeout=60).run()
assert not at.exception, at.exception
text = "\n".join(str(getattr(el, "value", el)) for kind in
                 ("markdown", "caption", "error", "warning", "success", "info",
                  "subheader", "header", "code") for el in getattr(at, kind))
assert "TEST8_PROBE_TOKEN" in text, "the env reference NAME should render"
assert "sekrit-value-77f2" not in text, \
    "the VALUE of a set environment variable reached the page"
EOF
echo "ok 8 - auth shows the env-var NAME and set-ness; the value never renders"

echo "Test8 succeeded"
