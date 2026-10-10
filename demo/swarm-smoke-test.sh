#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [[ "$(docker info --format '{{.Swarm.LocalNodeState}}')" != inactive ]]; then
  echo 'Refusing to run: Docker must not already be in Swarm mode.' >&2
  exit 1
fi

stack="platform-demo-${RANDOM}-$$"
network="${stack}-edge"
secret="${stack}-db-password"
image="platform-api:${stack}"
secret_file="$(mktemp)"
swarm_initialized=false
network_created=false
secret_created=false
stack_deployed=false
image_built=false

cleanup() {
  local status=$?
  local cleanup_failed=false
  local service type name swarm_state
  trap - EXIT
  set +e
  if [[ "$stack_deployed" == true ]]; then
    docker stack rm "$stack" >/dev/null 2>&1 || true
    service='pending'
    for _ in {1..30}; do
      if ! service="$(docker service ls --filter "name=${stack}_" --format '{{.Name}}' 2>/dev/null)"; then
        echo 'Could not verify that temporary Swarm services were removed.' >&2
        cleanup_failed=true
        service='unavailable'
        break
      fi
      [[ -z "$service" ]] && break
      sleep 1
    done
    if [[ -n "$service" && "$service" != unavailable ]]; then
      echo "Temporary Swarm services remain after cleanup: $service" >&2
      cleanup_failed=true
    fi
  fi
  retry_remove() {
    local resource_type="$1"
    local resource_name="$2"
    if ! docker info >/dev/null 2>&1; then
      echo "Docker is unavailable while removing temporary $resource_type: $resource_name" >&2
      return 1
    fi
    for _ in {1..30}; do
      if ! docker "$resource_type" inspect "$resource_name" >/dev/null 2>&1; then return 0; fi
      if docker "$resource_type" rm "$resource_name" >/dev/null 2>&1 && ! docker "$resource_type" inspect "$resource_name" >/dev/null 2>&1; then return 0; fi
      sleep 1
    done
    echo "Could not remove temporary Docker $resource_type: $resource_name" >&2
    return 1
  }
  if [[ "$secret_created" == true ]]; then retry_remove secret "$secret" || cleanup_failed=true; fi
  if [[ "$stack_deployed" == true ]]; then retry_remove volume "${stack}_postgres_data" || cleanup_failed=true; fi
  if [[ "$network_created" == true ]]; then retry_remove network "$network" || cleanup_failed=true; fi
  if [[ "$swarm_initialized" == true ]]; then
    docker swarm leave --force >/dev/null 2>&1 || true
    swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null)"
    if [[ "$swarm_state" != inactive ]]; then
      echo "Temporary Swarm is still active after cleanup (state: ${swarm_state:-unavailable})." >&2
      cleanup_failed=true
    fi
  fi
  if [[ "$image_built" == true ]]; then retry_remove image "$image" || cleanup_failed=true; fi
  if ! rm -f -- "$secret_file"; then
    echo "Could not remove the temporary secret file: $secret_file" >&2
    cleanup_failed=true
  fi
  if [[ "$status" -eq 0 && "$cleanup_failed" == true ]]; then status=1; fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

openssl rand -hex 32 > "$secret_file"
docker swarm init >/dev/null
swarm_initialized=true
docker network create --driver overlay --attachable "$network" >/dev/null
network_created=true
docker secret create "$secret" "$secret_file" >/dev/null
secret_created=true
docker build --tag "$image" demo/api
image_built=true

export DEMO_IMAGE="$image"
export DEMO_STACK="$stack"
export DEMO_EDGE_NETWORK="$network"
export DEMO_SECRET="$secret"
stack_deployed=true
docker stack deploy --compose-file demo/swarm-stack.yaml "$stack"

if ! docker run --rm --network "$network" -e "DEMO_SWARM_API=${stack}_api" \
    --entrypoint sh curlimages/curl:8.22.0 -ec \
    'i=0; while [ "$i" -lt 60 ]; do if curl --connect-timeout 2 --max-time 5 --fail --silent "http://${DEMO_SWARM_API}:8080/health/ready" >/dev/null 2>&1; then exit 0; fi; i=$((i + 1)); sleep 2; done; exit 1'; then
  docker service logs --raw --tail 60 "${stack}_api" 2>&1 || true
  docker service logs --raw --tail 60 "${stack}_database" 2>&1 || true
  echo 'Swarm API did not become ready through the overlay.' >&2
  exit 1
fi

location="$(docker run --rm --network "$network" curlimages/curl:8.22.0 \
  --connect-timeout 2 --max-time 5 --fail --silent --show-error --dump-header - --output /dev/null \
  -X POST -H 'Content-Type: application/json' --data '{"body":"Swarm smoke test note"}' \
  "http://${stack}_api:8080/api/notes" \
  | awk 'tolower($1) == "location:" { gsub(sprintf("%c", 13), "", $2); print $2 }')"
[[ "$location" == /api/notes/* ]] || { echo "Create returned an invalid Location: $location" >&2; exit 1; }
docker run --rm --network "$network" curlimages/curl:8.22.0 \
  --connect-timeout 2 --max-time 5 --fail --silent --show-error \
  "http://${stack}_api:8080${location}" | grep 'Swarm smoke test note' >/dev/null
docker run --rm --network "$network" curlimages/curl:8.22.0 \
  --connect-timeout 2 --max-time 5 --fail --silent --show-error \
  "http://${stack}_api:8080/api/notes" | grep 'Swarm smoke test note' >/dev/null
invalid_status="$(docker run --rm --network "$network" curlimages/curl:8.22.0 \
  --connect-timeout 2 --max-time 5 --silent --output /dev/null --write-out '%{http_code}' -X POST \
  -H 'Content-Type: application/json' --data '{"body":"   "}' \
  "http://${stack}_api:8080/api/notes")"
[[ "$invalid_status" == 400 ]] || { echo "Invalid note returned $invalid_status, expected 400." >&2; exit 1; }

echo 'PASS: one-node Swarm scheduling, isolated overlay, secret delivery, database readiness, create/Location/read, list, and validation.'
