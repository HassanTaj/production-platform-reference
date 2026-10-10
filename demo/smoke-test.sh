#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
export MSYS_NO_PATHCONV=1
export DEMO_HTTP_PORT="$((20000 + RANDOM % 20000))"
secret_file="demo/secrets/db_password.txt"
created_secret=false
created_secret_dir=false

project="platform-reference-smoke-${RANDOM}-$$"
compose=(docker compose --project-name "$project" --file demo/compose.yaml)
cleanup() {
  local status=$?
  local cleanup_failed=false
  local remaining
  trap - EXIT
  set +e

  if ! "${compose[@]}" down --volumes --remove-orphans --rmi local >/dev/null 2>&1; then
    echo 'Could not clean up the temporary Compose project.' >&2
    cleanup_failed=true
  fi
  if ! docker info >/dev/null 2>&1; then
    echo 'Docker is unavailable; temporary Compose resources could not be verified.' >&2
    cleanup_failed=true
  else
    for resource in containers volumes networks images; do
      case "$resource" in
        containers) if ! remaining="$(docker ps --all --quiet --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then echo 'Could not verify temporary Compose containers.' >&2; cleanup_failed=true; continue; fi ;;
        volumes) if ! remaining="$(docker volume ls --quiet --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then echo 'Could not verify temporary Compose volumes.' >&2; cleanup_failed=true; continue; fi ;;
        networks) if ! remaining="$(docker network ls --quiet --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then echo 'Could not verify temporary Compose networks.' >&2; cleanup_failed=true; continue; fi ;;
        images) if ! remaining="$(docker image ls --quiet --filter "label=com.docker.compose.project=$project" 2>/dev/null)"; then echo 'Could not verify temporary Compose images.' >&2; cleanup_failed=true; continue; fi ;;
      esac
      if [[ -n "$remaining" ]]; then
        echo "Temporary Compose $resource remain after cleanup: $remaining" >&2
        cleanup_failed=true
      fi
    done
  fi
  if [[ "$created_secret" == true ]]; then
    if ! rm -f -- "$secret_file"; then
      echo "Could not remove the temporary database password file: $secret_file" >&2
      cleanup_failed=true
    fi
  fi
  if [[ "$created_secret_dir" == true ]]; then rmdir demo/secrets 2>/dev/null || true; fi
  if [[ "$status" -eq 0 && "$cleanup_failed" == true ]]; then status=1; fi
  exit "$status"
}
trap cleanup EXIT

if [[ ! -d demo/secrets ]]; then
  created_secret_dir=true
  mkdir -p demo/secrets
fi
if [[ ! -f "$secret_file" ]]; then
  created_secret=true
  openssl rand -hex 32 > "$secret_file"
fi

"${compose[@]}" up --build --detach
ready=false
for _ in {1..45}; do
  if curl --fail --silent --show-error -H 'Host: platform.localhost' \
      "http://127.0.0.1:${DEMO_HTTP_PORT}/health/ready" >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  "${compose[@]}" logs
  echo 'API did not become ready through the edge.' >&2
  exit 1
fi

"${compose[@]}" exec --no-TTY database psql -U platform -d platform -c 'DROP TABLE notes' >/dev/null
not_ready_response="$(curl --silent --show-error --write-out $'\n%{http_code}' \
  -H 'Host: platform.localhost' "http://127.0.0.1:${DEMO_HTTP_PORT}/health/ready" || true)"
not_ready_status="${not_ready_response##*$'\n'}"
[[ "$not_ready_status" == 503 ]] || { echo "Missing schema returned $not_ready_status, expected 503." >&2; exit 1; }
"${compose[@]}" exec --no-TTY database psql -U platform -d platform \
  -c 'CREATE TABLE IF NOT EXISTS notes (id uuid PRIMARY KEY, body varchar(500) NOT NULL, created_at timestamptz NOT NULL DEFAULT now())'

location="$(curl --fail --silent --show-error --dump-header - -X POST \
  -H 'Host: platform.localhost' -H 'Content-Type: application/json' \
  --data '{"body":"Smoke test note"}' "http://127.0.0.1:${DEMO_HTTP_PORT}/api/notes" \
  | awk 'tolower($1) == "location:" { gsub(sprintf("%c", 13), "", $2); print $2 }')"
[[ "$location" == /api/notes/* ]] || { echo "Create returned an invalid Location: $location" >&2; exit 1; }
curl --fail --silent --show-error -H 'Host: platform.localhost' \
  "http://127.0.0.1:${DEMO_HTTP_PORT}${location}" | grep 'Smoke test note' >/dev/null
curl --fail --silent --show-error -H 'Host: platform.localhost' \
  "http://127.0.0.1:${DEMO_HTTP_PORT}/api/notes" | grep 'Smoke test note' >/dev/null
invalid_response="$(curl --silent --show-error --write-out $'\n%{http_code}' -X POST \
  -H 'Host: platform.localhost' -H 'Content-Type: application/json' \
  --data '{"body":"   "}' "http://127.0.0.1:${DEMO_HTTP_PORT}/api/notes" || true)"
invalid_status="${invalid_response##*$'\n'}"
[[ "$invalid_status" == 400 ]] || { echo "Invalid note returned $invalid_status, expected 400." >&2; exit 1; }
echo 'PASS: edge routing, database and schema readiness, create/Location/read, list, and input validation.'
