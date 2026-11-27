# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0
"""Seed the Plane board of an do-agent-aws instance: no setup wizard, no manual login, a board to land on.

Run by ./plane.sh seed (and ./plane.sh up) inside the Plane api container, through Plane's own Django shell
(manage.py shell -c): the short command there reads KEY=value lines from stdin into SEED up to a "__SEED_PY__" line,
then executes the rest of stdin, which is this file. The lines are plane.env (PLANE_ADMIN_EMAIL,
PLANE_ADMIN_PASSWORD, PLANE_API_KEY, ...) and PLANE_WORKSPACE, PLANE_PROJECT_NAME, PLANE_PROJECT_IDENTIFIER, so no
secret is ever on a command line, in a file in an image or in the output.
Idempotent; every start re-applies it, so a new plane.env over an old data volume takes effect:
  - the admin user (password set only when it does not match, so open sessions stay valid), its profile marked
    onboarded with the product tours done, and an InstanceAdmin row;
  - the instance flags is_setup_done and is_signup_screen_visited, the condition the API checks, and on the first
    seed is_telemetry_enabled off (plane.sh also points Plane's metrics exporter at a closed loopback port and gives
    the services no egress, so no push leaves, before this seed or after it);
  - the workspace (admin member) and the agent's API token with exactly the given value (header X-Api-Key);
  - the project, created through Plane's own REST API (POST /api/v1/workspaces/<slug>/projects/), because that
    path also creates its default states (the board's columns), its identifier and its admin membership, which a
    bare ORM create does not; then the admin's display filters for it set to the Kanban layout (first seed only);
  - finally cache.clear(): /api/instances/ is served from the cache, and the web app gates the whole app on the
    SERVED is_setup_done - a DB write alone leaves the "Get started" wall up. ./plane.sh asserts the served value.
Prints summary lines without secrets, and PROJECT_ID=<uuid>.

Provenance: the seed of the maintainers' own Plane (seed_admin.py and seed_workspace.py, proven on makeplane/*:v1.4.2
2026-08-25), checked against Plane v1.4.2 (apps/api/plane: db/models, license/models, api/views/project.py,
license/api/views/instance.py).
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

from django.core.cache import cache
from plane.db.models import APIToken, Profile, Project, ProjectUserProperty, User, Workspace, WorkspaceMember
from plane.license.models import Instance, InstanceAdmin


# The http(s) URLs this script builds itself go through one opener, with the scheme checked first: file: or any other
# scheme is refused before a request is made (the urllib default would open it)
_HTTP_OPENER = urllib.request.build_opener()


def http_open(req, timeout):
    """urllib.request.urlopen for an http or https URL (or Request) only; ValueError for any other scheme."""
    url = req.full_url if isinstance(req, urllib.request.Request) else req
    if urllib.parse.urlsplit(url).scheme not in ("http", "https"):
        raise ValueError("refusing a non-http(s) URL: %r" % (url,))
    return _HTTP_OPENER.open(req, timeout=timeout)

ADMIN = 20
TOKEN_LABEL = "do-agent-aws"
API = "http://127.0.0.1:8000"

SEED = globals().get("SEED")  # set by the shell command (see above)
if not SEED:
    print("seed: ERROR - no settings on stdin (run me through ./plane.sh seed)", file=sys.stderr)
    sys.exit(1)
S = {"email": SEED["PLANE_ADMIN_EMAIL"], "password": SEED["PLANE_ADMIN_PASSWORD"], "api_key": SEED["PLANE_API_KEY"],
     "workspace": SEED["PLANE_WORKSPACE"], "project_name": SEED["PLANE_PROJECT_NAME"],
     "project_identifier": SEED["PLANE_PROJECT_IDENTIFIER"]}
email = S["email"].strip().lower()
display = email.split("@", 1)[0]


def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"X-Api-Key": S["api_key"], "Content-Type": "application/json"})
    try:
        with http_open(req, 30) as r:
            return r.status, json.loads(r.read() or b"null")
    except urllib.error.HTTPError as e:
        return e.code, (e.read() or b"")[:300].decode(errors="replace")


inst = Instance.objects.first()
if inst is None:
    print("seed: ERROR - no Instance row yet (the api's register_instance has not run)", file=sys.stderr)
    sys.exit(1)

user, created = User.objects.get_or_create(email=email, defaults={
    "username": email, "display_name": display, "first_name": display, "is_active": True,
    "is_email_verified": True, "is_password_autoset": False})
pw_changed = created or not user.check_password(S["password"])
if pw_changed:
    user.set_password(S["password"])
user.is_active = user.is_email_verified = True
user.is_password_autoset = user.is_password_reset_required = False
user.save()
print(f"seed: admin {email} {'created' if created else 'exists'}, password {'set' if pw_changed else 'unchanged'}")

ws, ws_created = Workspace.objects.get_or_create(slug=S["workspace"], defaults={"name": S["workspace"], "owner": user})
member, _ = WorkspaceMember.objects.get_or_create(workspace=ws, member=user, defaults={"role": ADMIN})
if member.role != ADMIN or not member.is_active:
    member.role, member.is_active = ADMIN, True
    member.save()
print(f"seed: workspace {ws.slug} {'created' if ws_created else 'exists'}")

profile, _ = Profile.objects.get_or_create(user=user)
profile.is_onboarded = profile.is_tour_completed = True
if hasattr(profile, "is_navigation_tour_completed"):
    profile.is_navigation_tour_completed = True
profile.onboarding_step = {k: True for k in (profile.onboarding_step or {})} or profile.onboarding_step
profile.last_workspace_id = ws.id
profile.save()

_, adm_created = InstanceAdmin.objects.get_or_create(instance=inst, user=user, defaults={"role": ADMIN})
flags = [f for f in ("is_setup_done", "is_signup_screen_visited") if not getattr(inst, f)]
for f in flags:
    setattr(inst, f, True)
# The first seed (setup not done yet) also turns Plane's telemetry off - the beat worker otherwise pushes instance
# metrics every 6 hours (license/bgtasks/telemetry_metrics.py), to the closed loopback port plane.sh sets as
# OTLP_ENDPOINT; god-mode can turn it back on, and later seeds leave it as set there
if "is_setup_done" in flags and inst.is_telemetry_enabled:
    inst.is_telemetry_enabled = False
    flags.append("is_telemetry_enabled=False")
if flags:
    inst.save(update_fields=[f.split("=")[0] for f in flags])
print(f"seed: instance admin {'created' if adm_created else 'exists'}; flags set: {flags or 'already set'}")

token = APIToken.objects.filter(user=user, label=TOKEN_LABEL).first()
if token is None:
    APIToken.objects.create(user=user, workspace=ws, label=TOKEN_LABEL, token=S["api_key"],
                            description="do-agent-aws goal mirror (/agent/plane-sync.py)")
    tok_state = "created"
elif (token.token, token.workspace_id, token.is_active, token.expired_at) != (S["api_key"], ws.id, True, None):
    token.token, token.workspace, token.is_active, token.expired_at = S["api_key"], ws, True, None
    token.save()
    tok_state = "updated"
else:
    tok_state = "unchanged"
print(f"seed: agent API token (label {TOKEN_LABEL}) {tok_state}")

code, body = api("GET", f"/api/v1/workspaces/{ws.slug}/projects/")
if code != 200:
    print(f"seed: ERROR - the project list answered {code}: {body}", file=sys.stderr)
    sys.exit(1)
projects = body.get("results", body) if isinstance(body, dict) else body
proj = next((p for p in projects if p.get("identifier") == S["project_identifier"]), None)
proj_state = "exists"
if proj is None:
    code, proj = api("POST", f"/api/v1/workspaces/{ws.slug}/projects/",
                     {"name": S["project_name"], "identifier": S["project_identifier"],
                      "description": "The do-agent-aws autonomy loop's goals and fires, mirrored by /agent/plane-sync.py"})
    if code != 201:
        print(f"seed: ERROR - creating the project answered {code}: {proj}", file=sys.stderr)
        sys.exit(1)
    proj_state = "created"
project = Project.objects.get(pk=proj["id"])
# The board view: the admin's display filters for the project, set to the Kanban layout grouped by state when the
# seed creates the project (the create call above already made the row, with Plane's default list layout); later
# seeds leave the layout to whoever uses the board
prop, prop_created = ProjectUserProperty.objects.get_or_create(user=user, project=project)
layout_set = prop_created or proj_state == "created"
if layout_set:
    prop.display_filters = dict(prop.display_filters or {}, layout="kanban", group_by="state")
    prop.save()
print(f"seed: project {project.identifier} ({project.name}) {proj_state}; "
      f"layout {(prop.display_filters or {}).get('layout')}{' (set)' if layout_set else ''}")

cache.clear()
print("seed: django cache cleared - the served /api/instances/ now reflects the database")
print(f"PROJECT_ID={project.id}")
