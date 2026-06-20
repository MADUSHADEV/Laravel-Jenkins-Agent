# Laravel Jenkins Agent

Docker-based Jenkins inbound agent for building, testing, and deploying Laravel applications. Jenkins runs natively on the host VM; the agent, Redis, and ephemeral PostgreSQL run in Docker.

## Architecture

- **Jenkins Controller:** Runs natively on host VM (not in Docker).
- **Laravel Agent:** Custom inbound agent image with PHP, Composer, Node.js, Docker CLI, and Ansible.
- **Redis Cache:** `redis:7-alpine` for caching and queue management (always-on in Docker).
- **PostgreSQL:** Ephemeral per build — created at build start, destroyed after (not in `docker-compose.yml`).
- **Network:** Docker bridge network (`jenkins-net`) for agent/Redis/ephemeral PostgreSQL communication.

See [ARCHITECTURE.md](ARCHITECTURE.md) for detailed comparison of architecture options and network diagrams.

## Prerequisites on Host VM

1. Jenkins installed and running natively (or via Docker on host).
2. Docker Engine and Docker Compose plugin installed.
3. Reverse proxy (Nginx/Caddy) in front of Jenkins (recommended).

```bash
# Verify Jenkins is running
curl http://127.0.0.1:8080

# Verify Docker is running
docker --version
docker compose version
```

4. Create persistent Redis data path:

```bash
sudo mkdir -p /srv/redis_data
sudo chown -R 999:999 /srv/redis_data
```

5. Install Ansible on host VM (for managing deployments):

```bash
sudo apt update && sudo apt install -y ansible
```

## First-time Setup

1. Clone this repository on your VM:

```bash
git clone <your-github-repo-url>
cd Laravel-Jenkins-Agent
```

2. Copy env template:

```bash
cp .env.example .env
```

3. Detect Docker group GID and update `.env`:

```bash
getent group docker | cut -d: -f3
```

Set the returned value as `DOCKER_GID`.

4. Open Jenkins and create a node:

- Go to **Manage Jenkins** → **Manage Nodes** → **New Node**
- **Node name:** value of `JENKINS_AGENT_NAME` from `.env` (default `laravel-agent-1`)
- **Type:** Permanent Agent
- **Remote root directory:** `/home/jenkins/agent`
- **Launch method:** Launch agent by connecting it to the controller
- **Enable WebSocket:** Checked

5. Copy node secret from the node page and set `JENKINS_SECRET` in `.env`.

6. Build and start the agent:

```bash
docker compose up --build -d
```

7. Verify:

```bash
docker compose ps
docker compose logs -f laravel-agent
docker compose logs -f redis
```

## Pipeline Usage

The agent has Docker socket access, so it can create ephemeral PostgreSQL containers per build.

### Basic Jenkinsfile

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

### Laravel .env for Pipeline

```env
DB_CONNECTION=pgsql
DB_HOST=test-postgres-${BUILD_NUMBER}
DB_PORT=5432
DB_DATABASE=laravel_test
DB_USERNAME=laravel
DB_PASSWORD=secret

CACHE_DRIVER=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=redis
REDIS_PORT=6379
```

## Reverse Proxy (Nginx)

Use Nginx/Caddy in front of Jenkins and terminate TLS there.

Nginx essentials:

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

If using a path prefix, set `JENKINS_PREFIX` in `.env` to match.

## Backup and Restore

### Redis Backup

```bash
# Backup
docker exec test-redis redis-cli BGSAVE
sudo cp /srv/redis_data/dump.rdb /backup/redis-dump-$(date +%F).rdb

# Restore
docker compose down
sudo cp /backup/redis-dump-YYYY-MM-DD.rdb /srv/redis_data/dump.rdb
sudo chown -R 999:999 /srv/redis_data/dump.rdb
docker compose up -d
```

## Security Notes

- Keep `.env` private and never commit real secrets.
- Do not expose Docker socket to untrusted containers.
- Inbound agent with Docker socket has high privileges on host; treat it as trusted.
- Restrict Jenkins admin access and enforce strong credentials.
- Redis is bound to internal Docker network only (not exposed externally).
- PostgreSQL is ephemeral and not exposed externally.

## Troubleshooting

### Agent can't connect to Jenkins

```bash
# Verify host.docker.internal resolves from inside agent
docker exec laravel-agent ping host.docker.internal

# Check Jenkins is running on host
curl http://127.0.0.1:8080

# Check agent logs
docker compose logs -f laravel-agent
```

### Redis connection refused

```bash
# Check Redis is running
docker compose ps redis

# Test Redis connection from agent
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

## File Structure

```
Laravel-Jenkins-Agent/
├── docker-compose.yml          # Agent + Redis services
├── .env                        # Environment variables (not committed)
├── .env.example                # Template for .env
├── ARCHITECTURE.md             # Detailed architecture guide
├── README.md                   # This file
├── .gitignore                  # Excludes .env
└── laravel-agent/
    ├── Dockerfile              # Agent image (PHP, Composer, Node, Docker CLI)
    └── entrypoint.sh           # Starts JNLP agent connection
```
