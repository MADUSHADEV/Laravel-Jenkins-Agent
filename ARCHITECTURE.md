# Laravel Jenkins Agent — Architecture Guide

## Overview

This project provides a Docker-based Jenkins inbound agent for building, testing, and deploying Laravel applications. Jenkins runs natively on the host VM, while the agent, Redis, and (ephemeral) PostgreSQL run inside Docker containers on a shared bridge network.

---

## Architecture Options Comparison

When designing a CI/CD pipeline for Laravel, you must decide how to manage build-time services like databases and caches. Three approaches exist:

---

### Option A: Always-On Services (Persistent)

```
┌──────────────────────────────────────────────────────┐
│                    Host VM                           │
│                                                      │
│  ┌──────────────┐                                    │
│  │   Jenkins    │                                    │
│  └──────┬───────┘                                    │
│         │ WebSocket                                  │
│         ▼                                            │
│  ┌──────────────────────────────────────────────┐    │
│  │         Docker Network (jenkins-net)         │    │
│  │                                              │    │
│  │  ┌──────────────┐  ┌─────────────────────┐  │    │
│  │  │ laravel-agent│──│  PostgreSQL (always) │  │    │
│  │  │              │──│  port 5432           │  │    │
│  │  │              │──│  Redis (always)      │  │    │
│  │  └──────────────┘  │  port 6379           │  │    │
│  │                      └─────────────────────┘  │    │
│  └──────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────┘
```

**How it works:**
- PostgreSQL and Redis containers run 24/7 via `docker-compose.yml`
- Data persists in Docker volumes between builds
- Agent connects to services using Docker service names (`postgres`, `redis`)
- Pipeline steps simply use the running services

**Jenkinsfile example:**
```groovy
pipeline {
  agent { label 'laravel-agent-1' }
  environment {
    DB_HOST = 'postgres'
    REDIS_HOST = 'redis'
  }
  stages {
    stage('Migrate') { steps { sh 'php artisan migrate --force' } }
    stage('Test')    { steps { sh 'php artisan test' } }
  }
}
```

**Pros:**
- Simplest pipeline — no container lifecycle management
- Fast startup — services are already running
- Persistent data useful for development/debugging

**Cons:**
- **Test pollution** — Build A leaves data in DB → Build B sees it → false positives/negatives
- **Resource waste** — containers consume RAM/CPU even when no builds are running
- **State drift** — over time, DB accumulates junk from failed builds
- **Flaky tests** — order-dependent tests pass/fail unpredictably

**Best for:** Development environments, quick prototypes, single-developer setups

---

### Option B: Fully Ephemeral Services (Per-Build)

```
┌──────────────────────────────────────────────────────┐
│                    Host VM                           │
│                                                      │
│  ┌──────────────┐                                    │
│  │   Jenkins    │                                    │
│  └──────┬───────┘                                    │
│         │ WebSocket                                  │
│         ▼                                            │
│  ┌──────────────────────────────────────────────┐    │
│  │         Docker Network (jenkins-net)         │    │
│  │                                              │    │
│  │  ┌──────────────┐  ┌─────────────────────┐  │    │
│  │  │ laravel-agent│──│ PostgreSQL (ephemeral)│  │   │
│  │  │              │   │ test-postgres-{N}   │  │    │
│  │  │  (Docker     │   └─────────────────────┘  │    │
│  │  │   socket)    │  ┌─────────────────────┐  │    │
│  │  │              │──│ Redis (ephemeral)    │  │    │
│  │  └──────────────┘  │ test-redis-{N}      │  │    │
│  │                      └─────────────────────┘  │    │
│  └──────────────────────────────────────────────┘    │
│                                                      │
│  Agent uses Docker socket to create/destroy:         │
│  docker run -d --name test-postgres-{BUILD_NUMBER}   │
│  docker run -d --name test-redis-{BUILD_NUMBER}      │
└──────────────────────────────────────────────────────┘
```

**How it works:**
- No PostgreSQL or Redis in `docker-compose.yml`
- Agent has Docker socket mounted (`/var/run/docker.sock`)
- Pipeline creates fresh containers at build start, destroys them at build end
- Each build gets an isolated, clean environment

**Jenkinsfile example:**
```groovy
pipeline {
  agent { label 'laravel-agent-1' }
  stages {
    stage('Start Services') {
      steps {
        sh """
          docker run -d --name test-postgres-${BUILD_NUMBER} \
            --network jenkins-net \
            -e POSTGRES_DB=laravel_test \
            -e POSTGRES_USER=laravel \
            -e POSTGRES_PASSWORD=secret \
            postgres:16-alpine

          docker run -d --name test-redis-${BUILD_NUMBER} \
            --network jenkins-net \
            redis:7-alpine
        """
      }
    }
    stage('Migrate') { steps { sh 'php artisan migrate --force' } }
    stage('Test')    { steps { sh 'php artisan test' } }
  }
  post {
    always {
      sh "docker rm -f test-postgres-${BUILD_NUMBER} test-redis-${BUILD_NUMBER} || true"
    }
  }
}
```

**Pros:**
- **Guaranteed clean state** — every build starts fresh
- **No test pollution** — impossible by design
- **Reproducible** — same results every time
- **Full isolation** — builds can't interfere with each other

**Cons:**
- **Complex pipeline** — must manage container lifecycle in Jenkinsfile
- **Slower startup** — ~3-5s to pull/start containers per build
- **More Docker overhead** — frequent create/destroy cycles
- **Harder debugging** — containers gone after build, logs harder to access

**Best for:** Production CI/CD, multi-team environments, strict test isolation

---

### Option C: Hybrid Approach (Recommended)

```
┌──────────────────────────────────────────────────────┐
│                    Host VM                           │
│                                                      │
│  ┌──────────────┐                                    │
│  │   Jenkins    │  ← Runs natively on host           │
│  │  (port 8080) │                                    │
│  └──────┬───────┘                                    │
│         │ WebSocket                                  │
│         ▼                                            │
│  ┌──────────────────────────────────────────────┐    │
│  │         Docker Network (jenkins-net)         │    │
│  │                                              │    │
│  │  ┌──────────────┐  ┌─────────────────────┐  │    │
│  │  │ laravel-agent│──│  Redis (always-on)  │  │    │
│  │  │              │   │  port 6379          │  │    │
│  │  │  (Docker     │   │  FLUSHALL at start  │  │    │
│  │  │   socket)    │   └─────────────────────┘  │    │
│  │  │              │                             │    │
│  │  │              │  ┌─────────────────────┐  │    │
│  │  │              │──│ PostgreSQL (ephemeral)│  │   │
│  │  └──────────────┘  │ test-postgres-{N}   │  │    │
│  │                      └─────────────────────┘  │    │
│  └──────────────────────────────────────────────────────┘
```

**How it works:**
- **Redis**: Always running in Docker, flushed at build start (`FLUSHALL`)
- **PostgreSQL**: Created fresh per build, destroyed after — no persistent data
- **Agent**: Connects to Jenkins through HTTPS reverse proxy (`https://jenkins.algowrite.com/`)
- **Docker socket**: Mounted so agent can create/destroy ephemeral PostgreSQL

**Jenkinsfile example:**
```groovy
pipeline {
  agent { label 'laravel-agent-1' }

  environment {
    DB_HOST     = "test-postgres-${env.BUILD_NUMBER}"
    DB_PORT     = '5432'
    DB_DATABASE = 'laravel_test'
    DB_USERNAME = 'laravel'
    DB_PASSWORD = 'secret'
    REDIS_HOST  = 'redis'
    REDIS_PORT  = '6379'
  }

  stages {
    stage('Start Test PostgreSQL') {
      steps {
        sh """
          docker run -d --name test-postgres-${env.BUILD_NUMBER} \
            --network jenkins-net \
            -e POSTGRES_DB=laravel_test \
            -e POSTGRES_USER=laravel \
            -e POSTGRES_PASSWORD=secret \
            postgres:16-alpine

          until docker exec test-postgres-${env.BUILD_NUMBER} pg_isready -U laravel; do
            sleep 1
          done
        """
      }
    }

    stage('Flush Redis') {
      steps {
        sh 'redis-cli -h redis FLUSHALL'
      }
    }

    stage('Checkout') {
      steps {
        checkout scm
      }
    }

    stage('Setup') {
      steps {
        sh '''
          composer install --no-interaction --prefer-dist
          cp .env.example .env
          php artisan key:generate
        '''
      }
    }

    stage('Migrate') {
      steps {
        sh 'php artisan migrate --force'
      }
    }

    stage('Test') {
      steps {
        sh 'php artisan test'
      }
    }
  }

  post {
    always {
      sh "docker rm -f test-postgres-${env.BUILD_NUMBER} || true"
    }
  }
}
```

**Pros:**
- **Clean DB per build** — PostgreSQL is ephemeral, no pollution
- **Fast Redis** — just `FLUSHALL` (~1ms) instead of container restart (~3s)
- **Balanced complexity** — pipeline manages only PostgreSQL lifecycle
- **Resource efficient** — only PostgreSQL spins up per build
- **Debuggable** — Redis stays alive for inspection between builds

**Cons:**
- Slightly more complex than fully persistent
- PostgreSQL container startup adds ~2-3s per build
- Docker socket access is a security consideration

**Best for:** Most Laravel CI/CD pipelines, team environments, balanced approach

---

## Comparison Matrix

| Aspect | Option A (Always-On) | Option B (Fully Ephemeral) | Option C (Hybrid) |
|--------|---------------------|---------------------------|-------------------|
| **Clean state per build** | No | Yes | Yes (DB) + flush (Redis) |
| **Pipeline complexity** | Low | High | Medium |
| **Startup time** | 0s | ~5-8s | ~2-3s |
| **Resource usage** | Always | Per-build | Mostly always |
| **Test reliability** | Risk of pollution | Guaranteed clean | Guaranteed clean |
| **Data persistence** | Full | None | Redis only |
| **Debugging ease** | Easy | Hard (containers gone) | Medium |
| **Multi-developer** | Problematic | Excellent | Good |
| **Best for** | Dev/Prototype | Production CI | Most projects |

---

## Why Hybrid is Recommended

1. **PostgreSQL must be ephemeral**: Laravel migrations modify schema. Running migrations on a persistent DB means Build N+1 inherits Build N's state. Tests become order-dependent and flaky.

2. **Redis can be persistent**: Redis is stateless by nature. A `FLUSHALL` command clears all keys in <1ms. No need to restart the container. The overhead of creating/destroying a Redis container per build is unnecessary.

3. **Resource efficiency**: Redis uses ~10MB RAM. Keeping it always-on is negligible. PostgreSQL uses ~50-100MB but must be fresh per build.

4. **Pipeline simplicity**: Only one service (PostgreSQL) needs lifecycle management in the Jenkinsfile. Redis is just `FLUSHALL` — a single command.

---

## Network Architecture

### Container Communication

```
┌─────────────────────────────────────────────────────────┐
│              Docker Bridge Network (jenkins-net)        │
│                                                         │
│  ┌───────────────┐    ┌───────────────┐                │
│  │ laravel-agent │    │  test-redis   │                │
│  │ 172.18.0.2    │───▶│ 172.18.0.3    │                │
│  └───────┬───────┘    └───────────────┘                │
│          │                                              │
│          │  Docker socket                               │
│          ▼                                              │
│  ┌───────────────────┐                                  │
│  │ test-postgres-N   │  ← Created per build            │
│  │ 172.18.0.4        │  ← Destroyed after build        │
│  └───────────────────┘                                  │
│                                                         │
└─────────────────────────────────────────────────────────┘
                         │
                         │ host.docker.internal
                         ▼
┌─────────────────────────────────────────────────────────┐
│                     Host VM                             │
│                                                         │
│  ┌──────────────┐     ┌──────────────────────┐         │
│  │   Jenkins    │◄────│   Reverse Proxy      │         │
│  │  (port 8080) │     │  (port 80, no prefix)│         │
│  └──────────────┘     └──────────────────────┘         │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### DNS Resolution Inside Docker

| From | To | DNS Name | Resolves To |
|------|----|----------|-------------|
| Agent | Jenkins | `jenkins.algowrite.com` | Reverse proxy (HTTPS, external) |
| Agent | Redis | `redis` | Redis container IP (Docker DNS) |
| Agent | PostgreSQL | `test-postgres-{N}` | PostgreSQL container IP (Docker DNS) |
| Agent | Redis (alt) | `test-redis` | Redis container alias |
| Laravel app | Redis | `redis` | Redis container IP |
| Laravel app | PostgreSQL | `test-postgres-{N}` | PostgreSQL container IP |

---

## Host VM Network Configuration

### Reverse Proxy (Nginx)

If using Nginx as a reverse proxy in front of Jenkins (no prefix):

```nginx
server {
    listen 80;
    server_name jenkins.example.com;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # WebSocket support for JNLP agent
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

### Firewall Rules

```bash
# Allow Jenkins port (if not using reverse proxy)
sudo ufw allow 8080/tcp

# Allow reverse proxy port
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Docker bridge network handles internal communication
# No need to expose PostgreSQL (5432) or Redis (6379) externally
```

---

## Jenkins Node Configuration

In Jenkins UI → Manage Jenkins → Manage Nodes → New Node:

| Setting | Value |
|---------|-------|
| **Node name** | `laravel-agent-1` (match `JENKINS_AGENT_NAME` in `.env`) |
| **Type** | Permanent Agent |
| **Remote root directory** | `/home/jenkins/agent` |
| **Launch method** | Launch agent by connecting it to the controller |
| **Enable WebSocket** | Checked |
| **Labels** | `laravel` (optional, for `agent { label 'laravel' }`) |

---

## Environment Variables Reference

### .env (Docker Compose)

```bash
# Jenkins (runs on host VM, behind reverse proxy)
JENKINS_URL=https://jenkins.algowrite.com/   # Agent connects through HTTPS reverse proxy
JENKINS_AGENT_NAME=laravel-agent-1
JENKINS_SECRET=<your-node-secret>

# Docker build
DOCKER_GID=998                  # Host Docker group GID

# Redis (always-on in Docker)
REDIS_DATA_PATH=/srv/redis_data

# Misc
ANSIBLE_FILES_PATH=/home/admin
TZ=Asia/Kolkata
```

### Jenkinsfile Environment Variables

```bash
# Database (ephemeral PostgreSQL per build)
DB_HOST=test-postgres-${BUILD_NUMBER}   # Docker service name
DB_PORT=5432
DB_DATABASE=laravel_test
DB_USERNAME=laravel
DB_PASSWORD=secret

# Cache/Queue
REDIS_HOST=redis                        # Docker service name
REDIS_PORT=6379
```

---

## Data Flow: Build Pipeline

```
1. Jenkins triggers build
   │
   ▼
2. Agent receives build job via WebSocket
   │
   ▼
3. Agent creates ephemeral PostgreSQL container
   docker run -d --name test-postgres-{N} --network jenkins-net postgres:16-alpine
   │
   ▼
4. Agent flushes Redis
   redis-cli -h redis FLUSHALL
   │
   ▼
5. Agent checks out Laravel code
   git clone <repo>
   │
   ▼
6. Agent installs dependencies
   composer install
   npm install
   │
   ▼
7. Agent runs migrations on fresh PostgreSQL
   php artisan migrate --force
   │
   ▼
8. Agent runs tests
   php artisan test
   │
   ▼
9. Agent builds artifacts (if needed)
   npm run build
   │
   ▼
10. Agent cleans up PostgreSQL
    docker rm -f test-postgres-{N}
    │
    ▼
11. Build result reported to Jenkins
```

---

## Security Considerations

1. **Docker Socket**: The agent container mounts `/var/run/docker.sock`, giving it full control over the host Docker daemon. This is powerful but risky — treat the agent as trusted.

2. **PostgreSQL Credentials**: Use strong passwords even for ephemeral containers. Credentials are in environment variables, not hardcoded.

3. **Redis**: Not exposed externally. Only accessible within `jenkins-net` Docker network.

4. **Jenkins Secret**: Never commit `JENKINS_SECRET` to version control. Use `.env` file (excluded via `.gitignore`).

5. **Network Isolation**: PostgreSQL and Redis are only accessible from the Docker network. No host port bindings.

---

## Troubleshooting

### Agent can't connect to Jenkins

```bash
# Verify Jenkins is accessible through reverse proxy
curl -v https://jenkins.algowrite.com/login

# Check agent logs
docker compose logs -f laravel-agent

# Verify agent can resolve the domain
docker exec laravel-agent nslookup jenkins.algowrite.com
```

### PostgreSQL not ready

```bash
# Check ephemeral PostgreSQL container
docker ps | grep test-postgres
docker logs test-postgres-{N}

# Verify it's on jenkins-net
docker network inspect jenkins-net
```

### Redis connection refused

```bash
# Check Redis is running
docker compose ps redis

# Test Redis connection
docker exec laravel-agent redis-cli -h redis ping
# Should return: PONG
```

### Agent can't create Docker containers

```bash
# Verify Docker socket is mounted
docker exec laravel-agent ls -la /var/run/docker.sock

# Check Docker GID matches host
docker exec laravel-agent id jenkins
# Should show jenkins user in docker group
```

---

## File Structure

```
Laravel-Jenkins-Agent/
├── docker-compose.yml          # Agent + Redis services
├── .env                        # Environment variables (not committed)
├── .env.example                # Template for .env
├── ARCHITECTURE.md             # This file
├── README.md                   # Setup instructions
├── .gitignore                  # Excludes .env
└── laravel-agent/
    ├── Dockerfile              # Agent image (PHP, Composer, Node, Docker CLI)
    └── entrypoint.sh           # Starts JNLP agent connection
```
