#!/bin/bash
set -e

WORKDIR_PATH="${JENKINS_AGENT_WORKDIR:-/home/jenkins/agent}"

ARGS=(
  -url "${JENKINS_URL}"
  -secret "${JENKINS_SECRET}"
  -name "${JENKINS_AGENT_NAME}"
  -workDir "${WORKDIR_PATH}"
)

if [ "${JENKINS_WEB_SOCKET:-true}" = "true" ]; then
  ARGS+=( -webSocket )
fi

if [ -n "${JENKINS_TUNNEL:-}" ]; then
  ARGS+=( -tunnel "${JENKINS_TUNNEL}" )
fi

exec /usr/local/bin/jenkins-agent "${ARGS[@]}"
