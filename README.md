# Laravel Jenkins Agent with Docker Compose

This project sets up a Jenkins CI/CD environment using Docker Compose, featuring a dedicated Jenkins agent specifically configured for building and testing Laravel applications.

## Overview

The setup includes:

* **Jenkins Controller:** A standard Jenkins LTS instance running in a Docker container.
* **Laravel Agent:** A custom Jenkins inbound agent (JNLP) built using Docker, equipped with the necessary tools for Laravel development.

The agent connects automatically to the controller via JNLP once both containers are running.

## Agent Features

The custom `laravel-agent` Docker image includes:

* **Base:** `jenkins/inbound-agent:latest-jdk17`
* **PHP:** Version 8.3 with common Laravel extensions (cli, fpm, common, mysql, pgsql, sqlite, zip, gd, mbstring, curl, xml, bcmath) installed from `packages.sury.org`.
* **Composer:** Latest version installed globally.
* **Node.js:** Latest LTS version including `npm`.
* **Git:** For source code management.
* **Docker CLI:** Allows the agent to run Docker commands (build, push, etc.) by mounting the host's Docker socket (`/var/run/docker.sock`).

## Prerequisites

* **Docker:** Ensure Docker is installed and running on your system.
* **Docker Compose:** Ensure Docker Compose is installed.

## Setup Instructions

1.  **Clone the Repository (if applicable):**
    ```bash
    git clone <your-repository-url>
    cd <your-repository-name>
    ```

2.  **Docker Socket Permissions (Linux/macOS):**
    The agent container needs access to the host's Docker socket. The `Dockerfile` attempts to add the `jenkins` user to a `docker` group with GID `999`. If you encounter permission errors when running Docker commands inside the agent, you **must** find your host's Docker group GID and update the `Dockerfile`:
    * Find the GID on your host:
        ```bash
        getent group docker | cut -d: -f3
        ```
    * Replace `999` in the `laravel-agent/Dockerfile` with the correct GID:
        ```dockerfile
        # ...
        RUN groupadd --gid <YOUR_HOST_DOCKER_GID> docker || true
        RUN usermod -aG docker jenkins
        # ...
        ```
    * If you change the GID, you'll need to rebuild the image using the `--build` flag.

3.  **Configure Jenkins Controller:**
    * Start the Jenkins controller for the first time:
        ```bash
        docker compose up -d jenkins-controller
        ```
    * Access Jenkins UI at `http://localhost:8080/jenkins`.
    * Complete the initial setup (get admin password, install suggested plugins, create admin user).
    * Navigate to **Manage Jenkins > Nodes > New Node**.
    * Enter Node Name: `laravel-agent-1` (must match `JENKINS_AGENT_NAME` in `docker-compose.yml`).
    * Select **Permanent Agent** and click **Create**.
    * Configure the agent:
        * **Remote root directory:** `/home/jenkins/agent`
        * **Labels:** `laravel docker` (or any labels you want to use)
        * **Usage:** Use this node as much as possible
        * **Launch method:** **Launch agent by connecting it to the controller**
    * Click **Save**.

4.  **Get Agent Secret:**
    * Go back to the Nodes list and click on `laravel-agent-1`.
    * Find the connection command and copy the **secret** value (a long hexadecimal string).

5.  **Update `docker-compose.yml`:**
    * Open the `docker-compose.yml` file.
    * Replace the placeholder value for `JENKINS_SECRET` under the `laravel-agent` service with the actual secret you copied.

6.  **Launch the Full Stack:**
    ```bash
    docker compose up --build -d
    ```
    The `--build` flag is necessary the first time or if you modified the `Dockerfile`.

7.  **Verify Agent Connection:**
    * Go back to **Manage Jenkins > Nodes**.
    * `laravel-agent-1` should show as connected (no red 'x').

## Using the Agent in Jenkinsfile

Target the agent in your `Jenkinsfile` using the labels you assigned during configuration (e.g., `laravel`):

```groovy
pipeline {
    agent {
        label 'laravel'
    }

    stages {
        stage('Build & Test') {
            steps {
                sh 'php --version'
                sh 'composer --version'
                sh 'node --version'
                sh 'npm --version'
                sh 'docker --version'
                // Your Laravel build/test commands here
            }
        }
    }
}
