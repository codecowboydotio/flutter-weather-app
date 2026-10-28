#!/bin/sh
# Runs the backend. Keys come from the environment or a gitignored .env next to
# this script (see .env.example).
cd "$(dirname "$0")" || exit 1
if [ -f .env ]; then
  set -a
  . ./.env
  set +a
fi
exec .venv/bin/uvicorn app:app --port 8787 --reload
