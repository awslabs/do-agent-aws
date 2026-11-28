You are working inside a Docker Sandbox microVM that has its own Docker Engine.
The directory {{EXAMPLE_DIR}} holds a small Docker Compose stack (read its
README.md first): a web service and a tests service.

Do the following, in order:

1. Build and start the web service of the stack with the Compose project name
   {{PROJECT}}.
2. Read the web service's health endpoint (/health on port 8080) from inside
   this sandbox. Do not publish any port: no `ports:` in Compose, no
   `docker run -p`, no `sbx ports`.
3. Run the stack's own tests as the tests container's main process
   (`docker compose run --rm -T tests` for project {{PROJECT}}). Do not use
   `docker exec` or `docker compose exec`. Read the passed and failed counts
   from the RESULT_JSON line the tests print.
4. Bring the stack down (project {{PROJECT}}, with volumes and orphans) and
   check that no container of project {{PROJECT}} is left.
5. Write {{REPORT}} (create its directory if needed) containing exactly one
   JSON object with these fields and nothing else:

   {
     "nonce": "{{NONCE}}",
     "project": "{{PROJECT}}",
     "health": {"status": "<status from /health>", "instance_id": "<instance_id from /health>"},
     "tests": {"passed": <integer>, "failed": <integer>},
     "published_ports": <number of ports the stack published, an integer>,
     "compose_down": <true only if step 4 left no container of the project>
   }

Use the values you observed, not values you expect. Do not modify any file
under {{EXAMPLE_DIR}}. When the report is written, reply with the single word
DONE.
