# Docker + Traefik Starter

Lifecycle scripts for projects that use Docker Compose with a shared Traefik reverse proxy. Each workspace gets isolated routing via `*.lvh.me` domains (resolves to 127.0.0.1).

## What it does

- **setup.sh** — Install project dependencies (edit to match your toolchain)
- **run.sh** — Start a shared Traefik instance, generate per-workspace routing config and compose overrides, start your Docker Compose stack, wait for health checks
- **teardown.sh** — Stop the Docker Compose stack, remove Traefik routing config

## Prerequisites

- Docker and Docker Compose v2
- No other process on ports 80 (Traefik) and 8080 (Traefik dashboard)

## Setup

Copy the starter files into your project root:

```bash
cp -r path/to/claudeship/starters/docker-traefik/.claudeship .claudeship/
cp path/to/claudeship/starters/docker-traefik/.claudeship.json .claudeship.json
```

Then edit the configuration variables in each script:

### `.claudeship/run.sh`

```bash
PROJECT_PREFIX="myapp"              # Docker project name prefix (e.g. "myapp-auth-refactor")
SERVICES=(api frontend)             # Services to expose via Traefik
HEALTHCHECK_SERVICES=(postgres redis) # Services to wait for health checks
BASE_COMPOSE="docker-compose.yml"   # Your compose file

# Port mapping for Traefik routing
declare -A SERVICE_PORTS=(
  [api]=8000
  [frontend]=80
)
```

### `.claudeship/teardown.sh`

Make sure `PROJECT_PREFIX` matches `run.sh`.

### `.claudeship/setup.sh`

Uncomment and edit the dependency install commands for your project.

## URL pattern

For a workspace named `auth-refactor` with `PROJECT_PREFIX="myapp"`:

| Service | URL |
|---------|-----|
| frontend | `http://myapp-auth-refactor.lvh.me` |
| api | `http://api-myapp-auth-refactor.lvh.me` |
| Traefik dashboard | `http://localhost:8080` |

## How it works

1. A single Traefik container runs globally (shared across all workspaces)
2. Each workspace gets a dynamic routing config in `~/.config/traefik-dynamic/`
3. Docker Compose services get a generated override that strips host ports and adds the `traefik-public` network
4. Traefik watches the config directory and routes `*.lvh.me` requests to the right workspace's containers
