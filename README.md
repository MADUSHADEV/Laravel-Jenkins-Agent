# Laravel Jenkins Agent on AWS VM

Practical Docker Compose blueprint for running a Jenkins controller plus a Laravel inbound agent on an AWS EC2 Linux VM.

## Architecture

- **Jenkins Controller:** `jenkins/jenkins:lts-jdk21` (JDK 21).
- **Laravel Agent:** custom inbound agent image with PHP, Composer, Node.js, Docker CLI, and Ansible.
- **Network:** private Docker bridge network (`jenkins-net`) for controller/agent communication.
- **Persistence:** host-mounted Jenkins home directory (recommended path: `/srv/jenkins_home`).

## AWS-ready defaults in this repo

- Controller image is configurable and defaults to `lts-jdk21`.
- Controller only binds HTTP to localhost by default (`127.0.0.1:8080`) to be placed behind a reverse proxy.
- Default timezone is set through `.env` using `TZ=Asia/Kolkata` (UTC+05:30).
- WebSocket mode is enabled for the inbound agent (avoids exposing port `50000`).
- Agent secret must be provided through `.env` (not hardcoded in Compose).
- Docker group ID for socket access is configurable via build arg (`DOCKER_GID`).

## Prerequisites on EC2

1. Install Docker Engine and Docker Compose plugin.
2. Ensure your EC2 security group does **not** expose `8080` publicly if using reverse proxy only.
3. Create persistent Jenkins home path:

```bash
sudo mkdir -p /srv/jenkins_home
sudo chown -R 1000:1000 /srv/jenkins_home
```

## First-time setup

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

4. For Debian hosts, keep `ANSIBLE_FILES_PATH` aligned with your actual admin user home in `.env` (default example uses `/home/admin`).

5. Start only controller first:

```bash
docker compose up -d jenkins-controller
```

6. Open Jenkins through your VM (or reverse proxy) at:

```text
http://<vm-or-domain>:8080/jenkins
```

7. Complete Jenkins initial setup (unlock, plugins, admin user).

8. Create node:

- Name: value of `JENKINS_AGENT_NAME` from `.env` (default `laravel-agent-1`)
- Type: Permanent Agent
- Remote root directory: `/home/jenkins/agent`
- Launch method: Launch agent by connecting it to the controller

9. Copy node secret from node page and set `JENKINS_SECRET` in `.env`.

10. Launch full stack:

```bash
docker compose up --build -d
```

11. Verify:

```bash
docker compose ps
docker compose logs -f laravel-agent
```

## Reverse proxy recommendation (Nginx)

Use Nginx/Caddy/ALB in front of Jenkins and terminate TLS there. Keep Jenkins container private when possible.

Nginx essentials:

- `proxy_set_header Host $host;`
- `proxy_set_header X-Forwarded-Proto https;`
- `proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;`
- WebSocket upgrade headers enabled.

If you use a path prefix, keep `JENKINS_PREFIX` aligned (default `/jenkins`).

## Upgrade strategy (safe and repeatable)

1. Backup `JENKINS_HOME`.
2. Pin desired controller image in `.env` (`JENKINS_CONTROLLER_IMAGE=jenkins/jenkins:lts-jdk21`).
3. Pull and restart:

```bash
docker compose pull
docker compose up -d
```

4. Validate UI, plugins, and agent connectivity.

## Backup and restore

### Backup

```bash
sudo tar -czf /tmp/jenkins-home-$(date +%F).tgz -C /srv jenkins_home
```

Copy archive to S3 or other remote storage.

### Restore

```bash
docker compose down
sudo rm -rf /srv/jenkins_home
sudo mkdir -p /srv/jenkins_home
sudo tar -xzf /path/to/backup.tgz -C /srv
sudo chown -R 1000:1000 /srv/jenkins_home
docker compose up -d
```

## Security notes

- Keep `.env` private and never commit real secrets.
- Do not expose Docker socket to controller unless required.
- Inbound agent with Docker socket has high privileges on host; treat it as trusted.
- Restrict Jenkins admin access and enforce strong credentials.

## Jenkinsfile example (Laravel agent)

```groovy
pipeline {
  agent { label 'laravel' }

  stages {
    stage('Tooling check') {
      steps {
        sh 'php -v'
        sh 'composer --version'
        sh 'node --version'
        sh 'npm --version'
        sh 'docker --version'
      }
    }
  }
}
