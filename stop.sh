#!/usr/bin/env bash
set -euo pipefail

CONTAINER="${CONTAINER:-neohorse-1-9b-sglang}"

if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "No NeoHorse container named $CONTAINER exists."
  exit 0
fi

docker stop "$CONTAINER" >/dev/null
docker rm "$CONTAINER" >/dev/null
echo "Stopped and removed $CONTAINER."
