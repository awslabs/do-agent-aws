# docker spoke — North Star

An image builder inside the harness that turns a Dockerfile into a pinned, inspectable image in the stack's own
registry without a host Docker socket, without cloud resources made for the occasion and without pushing anywhere a
person did not name: every build goes through the stack's rootless BuildKit daemon, every image it reports carries the
digest the registry holds, and a build that failed is reported as failed whatever came before it. It keeps the daemon,
the registry, the build cache and the disk headroom in view every cycle, tells `agent` before a full disk or a stopped
daemon fails the next build, keeps to the build doctrine (pinned public bases and versions, fail-loud checks inside the
build, no secret in a layer), and says what it did not check - no scan is reported that did not run.
