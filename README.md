# Production Platform Reference

A production-oriented reference for running a small multi-service platform with clear ingress, service, data, delivery, and operations boundaries.

Companion repositories in the Platform Engineering Lab: [Zero Trust Homelab](https://github.com/HassanTaj/zero-trust-homelab) demonstrates the private network boundary, and [AI-Native Platform Operations](https://github.com/HassanTaj/ai-native-platform-ops) demonstrates evidence-led operations.

The runnable examples are isolated local environments: a Compose stack routes through Traefik to a small .NET API backed by PostgreSQL, and a separate one-node Swarm exercise runs the same API/data path over an overlay network with no published service ports. Both are learning demos, not production deployments.

## Launch the reference stack

Requirements: Docker Engine with the Compose plugin. From the repository root, create a local database password file.

PowerShell:

```powershell
New-Item -ItemType Directory -Force demo/secrets | Out-Null
[guid]::NewGuid().ToString('N') | Set-Content -Encoding ascii -NoNewline demo/secrets/db_password.txt
docker compose -f demo/compose.yaml up --build --detach
```

Bash:

```bash
mkdir -p demo/secrets
openssl rand -hex 32 > demo/secrets/db_password.txt
docker compose -f demo/compose.yaml up --build --detach
```

Try the API through Traefik (the port is bound to loopback only):

```bash
curl -H "Host: platform.localhost" http://127.0.0.1:8080/health/ready
curl -H "Host: platform.localhost" http://127.0.0.1:8080/api/notes
curl -X POST -H "Host: platform.localhost" -H "Content-Type: application/json" -d '{"body":"First platform note"}' http://127.0.0.1:8080/api/notes
```

The create request returns `201 Created` with a `Location: /api/notes/{id}` header; a `GET` to that path returns the created note.

On Windows, use `curl.exe` and run each request on one line. Stop the demo with `docker compose -f demo/compose.yaml down`. This retains the named database volume. Add `--volumes` only when you intentionally want to erase this demo's local data. If port 8080 is occupied, set `DEMO_HTTP_PORT` to another local port before running Compose. The ignored password file must never be committed.

To run the isolated API smoke test, use Bash: `bash demo/smoke-test.sh`. It creates a uniquely named Compose project, verifies readiness, create/Location/read, list, and validation behavior, then removes only that project's containers, networks, volume, locally built image, and any password file it created.

To exercise the Swarm stack, use Bash: `bash demo/swarm-smoke-test.sh`. It initializes Swarm only when inactive, refuses to use an existing Swarm, and removes the temporary stack, secret, network, volume, image, and its own Swarm on exit.

## Preview the documentation

Requirements: Git and Node.js 20.17 or newer.

```bash
git clone https://github.com/HassanTaj/production-platform-reference.git
cd production-platform-reference
npm install --global mint
mint dev
```

Open <http://localhost:3000>.

Neither demo configures real TLS or connects to any VPS. The architecture and operational lessons are distilled from operated infrastructure, but all examples use synthetic domains, credentials, service names, and networks. See [demo scope](demo-scope.mdx) for exact boundaries.

## Publish the docs

Connect this GitHub repository to a Mintlify project and install Mintlify's GitHub App. After setup, pushes to the connected branch publish the docs. See the [Mintlify quickstart](https://mintlify.com/docs/quickstart).

## Documentation

- [Architecture](architecture.mdx)
- [Quickstart](quickstart.mdx)
- [Operational lessons](operational-lessons.mdx)
- [Compose-to-Swarm case study](case-study-compose-to-swarm.mdx)
- [Demo scope](demo-scope.mdx)
