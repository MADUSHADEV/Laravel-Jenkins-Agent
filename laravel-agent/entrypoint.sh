#!/bin/bash
set -e

# Use the JENKINS_URL, JENKINS_AGENT_NAME, and JENKINS_SECRET passed from docker-compose
# These are standard variables used by the jenkins/inbound-agent image's own entrypoint
exec /usr/local/bin/jenkins-agent \
  -url "${JENKINS_URL}" \
  -secret "${JENKINS_SECRET}" \
  -name "${JENKINS_AGENT_NAME}" \
  -workDir "/home/jenkins/agent"