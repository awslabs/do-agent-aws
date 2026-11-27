# plane/ - the self-hosted Plane board's seed

**The board is optional and off by default.** Plane community edition (`makeplane/*:v1.4.2`) is licensed AGPL-3.0
([LICENSE.txt at v1.4.2](https://github.com/makeplane/plane/blob/v1.4.2/LICENSE.txt)), so nothing of it is pulled,
started or shown unless `UI_PLANE=true` is set in `.env.local` - docs/manual/boards.md "Plane board" has the license note and the
steps. The files here are this repository's own (Apache-2.0); they run only while the board does.

`seed.py` is applied by `../plane.sh seed` (and `../plane.sh up`, which `../run.sh` calls) inside the board's api
container, through Plane's own Django shell. See docs/manual/boards.md "Plane board" for what the board is and how it is run.

## Recipe and provenance

- **Plane community v1.4.2**, the public images `makeplane/plane-{backend,frontend,space,admin,live,proxy}:v1.4.2`,
  run with the services, commands, environment and start order of upstream's
  `deployments/cli/community/docker-compose.yml` and `variables.env` at tag v1.4.2
  (github.com/makeplane/plane, commit 5f7d92784c403f76284f0f16718f320221dc7fec), as `docker container run`
  sidecars instead of a compose project: no service publishes a port, and each one keeps its upstream service name
  as a network alias, because the proxy image's Caddyfile and the services' own settings address each other by
  those names. Four departures from that file:
  - the services run on their own network, created `--internal` (no egress); only the proxy also joins the network
    the agent container joins, so no other board container can reach the agent;
  - `OTLP_ENDPOINT` (Plane's metrics exporter, upstream default `https://telemetry.plane.so`) points at a closed
    loopback port: the api queues a metrics push at every start (`register_instance`) that the worker runs before
    the seed can turn telemetry off (measured on v1.4.2);
  - the database, queue and object store get random passwords per install (upstream: `plane`/`plane` and
    `access-key`/`secret-key`), applied to an existing volume on every start;
  - the queue has a fixed hostname, `plane-mq`: RabbitMQ keeps its data under `rabbit@<hostname>`, and without one
    every new container started an empty node beside the old one in the volume (measured).
- **Object store**: upstream v1.4.2's image, `minio/minio`, can no longer be pulled anonymously from Docker Hub or
  quay.io (HTTP 401, checked 2026-10-13; makeplane/plane#9834, #9823). `.env` uses pgsty/silo
  (https://github.com/pgsty/silo, a fork of MinIO, AGPL-3.0) through its image `pgsty/minio:RELEASE.2026-08-04T00-00-00Z`,
  the image upstream's next release (v1.4.3-rc1, `deployments/cli/community/docker-compose.yml`) ships.
- **The seed** follows the seed of the maintainers' own Plane (scripts `seed_admin.py` and `seed_workspace.py`,
  proven on `makeplane/*:v1.4.2` 2026-08-25), with these differences, each from a measurement on v1.4.2:
  - the project is created through `POST /api/v1/workspaces/<slug>/projects/`: a bare ORM create makes no states
    (Plane creates them in that API view), so the board would have no columns;
  - the project name has no `-` or `.`: Plane refuses them (`Project.FORBIDDEN_IDENTIFIER_CHARS_PATTERN`);
  - the API token's value is chosen by `plane.sh` and stored in `wd/plane/plane.env`, so it is re-applied to an
    existing data volume instead of being shown once;
  - the admin password is set only when it does not match, so open sessions stay valid across restarts.
- **The cache trap**: `/api/instances/` is cached (two hours) and the web app gates the whole app on the SERVED
  `is_setup_done`. The seed ends with `cache.clear()` and `plane.sh` asserts the served value through Plane's
  proxy; a database write or a successful sign-in alone proves nothing about the setup wizard.
- **Sign-in needs a User-Agent**: Plane's email sign-in records the browser's User-Agent on the user
  (`users.last_login_uagent`, NOT NULL); a request without one fails with 500. `/agent/plane-signin.py` passes the
  browser's on.
