# Agents Guide — Laravel Jenkins Agent

## Project Overview

Docker-based Jenkins inbound agent for building, testing, and deploying Laravel applications. Jenkins runs natively on the host VM; the agent, Redis, and ephemeral PostgreSQL run in Docker containers.

## MANDATORY: Read ARCHITECTURE.md First

Before making any changes to this project, you **must** read [ARCHITECTURE.md](ARCHITECTURE.md). It contains:

- Full architecture diagrams and network topology
- Comparison of all 3 architecture options (Always-On, Fully Ephemeral, Hybrid)
- Why Hybrid approach was chosen
- DNS resolution and container communication details
- Data flow pipeline diagram
- Security considerations
- Troubleshooting guide

**Do not modify any file without understanding the architecture first.**

## Architecture Summary

| Component | Location | Lifecycle |
|-----------|----------|-----------|
| Jenkins Controller | Host VM (native) | Always running |
| Laravel Agent | Docker container | Always running |
| Redis (test-redis) | Docker container | Always running, FLUSHALL per build |
| PostgreSQL | Docker container | Ephemeral — created per build, destroyed after |

## Key Files

| File | Purpose |
|------|---------|
| `docker-compose.yml` | Defines agent + Redis services |
| `.env.example` | Environment variable template |
| `.env` | Actual environment variables (never commit) |
| `ARCHITECTURE.md` | Full architecture documentation |
| `README.md` | Setup and usage instructions |
| `laravel-agent/Dockerfile` | Agent image build (PHP, Composer, Node, Docker CLI) |
| `laravel-agent/entrypoint.sh` | Starts JNLP agent connection |

## Environment Variables

### docker-compose.yml

| Variable | Default | Description |
|----------|---------|-------------|
| `JENKINS_HTTP_PORT` | `8080` | Jenkins port on host VM |
| `JENKINS_PREFIX` | (empty) | Path prefix if behind reverse proxy |
| `JENKINS_AGENT_NAME` | `laravel-agent-1` | Agent node name in Jenkins |
| `JENKINS_SECRET` | (required) | Node secret from Jenkins UI |
| `DOCKER_GID` | `996` | Host Docker group GID |
| `REDIS_DATA_PATH` | `/srv/redis_data` | Redis persistent data path |
| `ANSIBLE_FILES_PATH` | `/home/admin` | Ansible files mount path |

### Pipeline Environment (Jenkinsfile)

| Variable | Value | Description |
|----------|-------|-------------|
| `DB_HOST` | `test-postgres-${BUILD_NUMBER}` | Ephemeral PostgreSQL container |
| `DB_PORT` | `5432` | PostgreSQL port |
| `DB_DATABASE` | `laravel_test` | Test database name |
| `DB_USERNAME` | `laravel` | Database user |
| `DB_PASSWORD` | `secret` | Database password |
| `REDIS_HOST` | `redis` | Docker service name for Redis |
| `REDIS_PORT` | `6379` | Redis port |

## Development Rules

1. **Never commit `.env`** — it contains secrets.
2. **Never modify the Dockerfile** unless adding new system dependencies.
3. **Always use `host.docker.internal`** when agent needs to reach host services.
4. **Always use Docker service names** (`redis`, `test-postgres-{N}`) for inter-container communication.
5. **Ephemeral PostgreSQL** — never add PostgreSQL to `docker-compose.yml`. It is created per build in the Jenkinsfile.
6. **Redis is for testing** — container name is `test-redis`, not `redis-cache`.
7. **Docker socket access** — the agent has full Docker control. Treat it as trusted.

## Common Tasks

### Adding a new PHP extension

Edit `laravel-agent/Dockerfile`, add to the `apt-get install` block under PHP extensions:

```dockerfile
RUN apt-get update && apt-get install -y \
    php8.3-<extension-name> \
    ...
```

### Changing Redis version

Update `docker-compose.yml`:

```yaml
redis:
  image: redis:<version>-alpine
```

### Updating agent to connect to different Jenkins URL

Update `JENKINS_URL` in `docker-compose.yml` environment section. Use `host.docker.internal` for host VM access.

### Fixing DOCKER_GID conflict during build

If build fails with `groupadd: GID '996' already exists`, the Dockerfile handles this automatically by checking if the GID is taken and renaming that group to `docker`. The logic in `Dockerfile` (lines 69-75):

```dockerfile
RUN set -eux; \
    if getent group docker > /dev/null; then \
      groupmod -g "${DOCKER_GID}" docker; \
    elif getent group "${DOCKER_GID}" > /dev/null; then \
      groupmod -n docker "$(getent group "${DOCKER_GID}" | cut -d: -f1)"; \
    else \
      groupadd --gid "${DOCKER_GID}" docker; \
    fi; \
    usermod -aG docker jenkins
```

To find your host's Docker GID: `getent group docker | cut -d: -f3`

### Adding a new pipeline service (e.g., Mailhog)

Add to `docker-compose.yml` as a new service. Do NOT add to `depends_on` for `laravel-agent` unless the agent needs direct access.

## Network

All containers communicate over `jenkins-net` bridge network. Do not expose PostgreSQL or Redis ports to the host unless explicitly needed for debugging.

## Support

- Architecture questions → Read `ARCHITECTURE.md`
- Setup issues → Read `README.md`
- Docker/agent issues → Check `laravel-agent/Dockerfile` and `entrypoint.sh`
