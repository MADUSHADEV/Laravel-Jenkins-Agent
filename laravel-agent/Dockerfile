# Start from the official Jenkins JNLP agent image with JDK 17
FROM jenkins/inbound-agent:latest-jdk17

# Switch to the root user to install system packages
USER root

# Install essential dependencies for adding repositories and general utilities
RUN apt-get update && apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release \
    unzip \
    git \
    sudo \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# === Install PHP 8.3 & Extensions ===
# Download the GPG key for the sury.org PHP repository
RUN curl -sSLo /usr/share/keyrings/deb.sury.org-archive-keyring.gpg https://packages.sury.org/php/apt.gpg
# Add the PHP repository to sources, signed by the key we just downloaded
RUN echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-archive-keyring.gpg] https://packages.sury.org/php/ $(lsb_release -sc) main" | tee /etc/apt/sources.list.d/sury-php.list > /dev/null
# Update package lists and install PHP with common Laravel extensions
RUN apt-get update && apt-get install -y \
    php8.3-cli \
    php8.3-fpm \
    php8.3-common \
    php8.3-mysql \
    php8.3-pgsql \
    php8.3-sqlite \
    php8.3-zip \
    php8.3-gd \
    php8.3-mbstring \
    php8.3-curl \
    php8.3-xml \
    php8.3-bcmath

# === Install Composer ===
# Download and install Composer globally
RUN curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer

# === Install Node.js & npm (LTS version) ===
# Add the NodeSource repository and install the LTS release
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
RUN apt-get install -y nodejs

# === Install Docker CLI ===
# This allows the agent to run Docker commands by connecting to the host's Docker socket
RUN curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
RUN echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
RUN apt-get update && apt-get install -y docker-ce-cli

# === Install Ansible ===
# Install Ansible directly from the official Debian repositories
RUN apt-get update && apt-get install -y ansible

# === Permissions ===
# Ensure a 'docker' group exists with the correct GID, then add the jenkins user to it.
# IMPORTANT: Replace 999 with your host's Docker group ID.
# Find it on your host with: getent group docker | cut -d: -f3
RUN \
  if ! getent group docker > /dev/null; then \
    if getent group 110 > /dev/null; then \
      EXISTING_GROUP=$(getent group 110 | cut -d: -f1); \
      groupdel $EXISTING_GROUP; \
    fi; \
    groupadd --gid 110 docker; \
  fi && \
  usermod -aG docker jenkins

# === Entrypoint ===
# Copy and set executable permissions for the entrypoint script (as root)
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Now, switch back to the standard, non-root jenkins user for runtime
USER jenkins

# The entrypoint script will start the JNLP connection to the Jenkins controller
ENTRYPOINT ["/entrypoint.sh"]