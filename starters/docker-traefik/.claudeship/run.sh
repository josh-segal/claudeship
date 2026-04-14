#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Workspace Run — start Docker Compose stack with Traefik routing
#
# Starts a project-specific Docker Compose stack behind a shared Traefik
# reverse proxy. Each workspace gets isolated routing via *.lvh.me domains.
#
# Environment: $WORKSPACE_PATH, $WORKSPACE_NAME, $MAIN_CHECKOUT
# ---------------------------------------------------------------------------

# === EDIT THESE to match your project ===

PROJECT_PREFIX="myapp"                        # Docker project name prefix
SERVICES=(api frontend)                       # Services to expose via Traefik
HEALTHCHECK_SERVICES=(postgres redis)         # Services to wait for before ready
BASE_COMPOSE="docker-compose.yml"             # Your compose file name
OVERRIDE_FILE="docker-compose.workspace.yml"  # Generated override (gitignored)

# Service port mapping: service_name -> container_port
# Used for Traefik load balancer config
declare -A SERVICE_PORTS=(
  [api]=8000
  [frontend]=80
)

# URL pattern: how workspace URLs are formed
# Available variables: $prefix (PROJECT_PREFIX-WORKSPACE_NAME), $service
url_for_service() {
  local service="$1"
  local prefix="${PROJECT_PREFIX}-${WORKSPACE_NAME}"
  if [ "$service" = "frontend" ]; then
    echo "http://${prefix}.lvh.me"
  else
    echo "http://${service}-${prefix}.lvh.me"
  fi
}

# === END EDIT SECTION ===

TRAEFIK_DYNAMIC="${HOME}/.config/traefik-dynamic"
TRAEFIK_COMPOSE="$TRAEFIK_DYNAMIC/docker-compose.traefik.yml"
PROJECT="${PROJECT_PREFIX}-${WORKSPACE_NAME}"

# ---------------------------------------------------------------------------
# Traefik management
# ---------------------------------------------------------------------------

ensure_traefik() {
  mkdir -p "$TRAEFIK_DYNAMIC"

  cat > "$TRAEFIK_COMPOSE" <<YAML
services:
  traefik:
    image: traefik:v3.4
    command:
      - "--api.insecure=true"
      - "--providers.file.directory=/etc/traefik/dynamic"
      - "--providers.file.watch=true"
      - "--entrypoints.web.address=:80"
    ports:
      - "80:80"
      - "8080:8080"
    volumes:
      - ${TRAEFIK_DYNAMIC}:/etc/traefik/dynamic:ro
    networks:
      - traefik-public
    restart: unless-stopped

networks:
  traefik-public:
    name: traefik-public
YAML

  if ! docker compose -f "$TRAEFIK_COMPOSE" -p traefik ps --status running 2>/dev/null | tail -n +2 | grep -q .; then
    echo "Starting Traefik reverse proxy..."
    docker compose -f "$TRAEFIK_COMPOSE" -p traefik up -d
  fi
}

# ---------------------------------------------------------------------------
# Routing config generation
# ---------------------------------------------------------------------------

generate_traefik_config() {
  mkdir -p "$TRAEFIK_DYNAMIC"

  local config_file="$TRAEFIK_DYNAMIC/${PROJECT}.yml"
  local prefix="${PROJECT_PREFIX}-${WORKSPACE_NAME}"

  # Build routers and services YAML
  local routers=""
  local services=""

  for svc in "${SERVICES[@]}"; do
    local port="${SERVICE_PORTS[$svc]:-80}"
    local url
    url="$(url_for_service "$svc")"
    local host
    host="$(echo "$url" | sed 's|http://||')"

    routers+="    ${PROJECT}-${svc}:
      rule: \"Host(\\\`${host}\\\`)\"
      entryPoints:
        - web
      service: ${PROJECT}-${svc}
"
    services+="    ${PROJECT}-${svc}:
      loadBalancer:
        servers:
          - url: \"http://${PROJECT}-${svc}-1:${port}\"
"
  done

  cat > "$config_file" <<YAML
http:
  routers:
${routers}
  services:
${services}
YAML
}

generate_override() {
  # Generate a compose override that strips host ports and adds the Traefik network
  local override="# Auto-generated workspace override — do not commit
services:"

  for svc in "${SERVICES[@]}"; do
    override+="
  ${svc}:
    ports: !override []
    networks:
      - default
      - traefik-public"
  done

  # Non-exposed services just strip ports
  for svc in "${HEALTHCHECK_SERVICES[@]}"; do
    override+="
  ${svc}:
    ports: !override []"
  done

  override+="

networks:
  traefik-public:
    external: true"

  echo "$override" > "$WORKSPACE_PATH/$OVERRIDE_FILE"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "Starting workspace \"${WORKSPACE_NAME}\"..."

# 1. Ensure Traefik is running
ensure_traefik

# 2. Generate compose override and Traefik routing
generate_override
generate_traefik_config

# 3. Start the stack
(cd "$WORKSPACE_PATH" && docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_FILE" -p "$PROJECT" up -d --build)

# 4. Wait for health checks
if [ ${#HEALTHCHECK_SERVICES[@]} -gt 0 ]; then
  echo "Waiting for services: ${HEALTHCHECK_SERVICES[*]}..."
  retries=15
  while [ $retries -gt 0 ]; do
    all_healthy=true
    for svc in "${HEALTHCHECK_SERVICES[@]}"; do
      healthy=$(cd "$WORKSPACE_PATH" && docker compose -f "$BASE_COMPOSE" -f "$OVERRIDE_FILE" -p "$PROJECT" ps "$svc" 2>/dev/null | grep -c "healthy" || true)
      if [ "$healthy" -eq 0 ]; then
        all_healthy=false
        break
      fi
    done
    if $all_healthy; then
      break
    fi
    retries=$((retries - 1))
    sleep 2
  done
fi

# 5. Print URLs
echo ""
echo "=== Workspace \"${WORKSPACE_NAME}\" services ready ==="
echo "  Worktree: $WORKSPACE_PATH"
for svc in "${SERVICES[@]}"; do
  url="$(url_for_service "$svc")"
  printf "  %-12s %s\n" "${svc}:" "$url"
done
echo "  Traefik:   http://localhost:8080"
echo ""
