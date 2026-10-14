#!/usr/bin/env bash
# Prints APP_VERSION / BUILD_ARGS for $GITHUB_ENV. Tags v1.2.3 set the build name; the run number is the build number.
set -euo pipefail
if [[ "${GITHUB_REF:-}" == refs/tags/v* ]]; then
  name="${GITHUB_REF_NAME#v}"
  [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "tag must look like v1.2.3, got $GITHUB_REF_NAME" >&2; exit 1; }
  echo "APP_VERSION=$name"
else
  name=$(sed -n 's/^version: *\([^+]*\).*/\1/p' pubspec.yaml)
  echo "APP_VERSION=$name-build$GITHUB_RUN_NUMBER"
fi
echo "BUILD_ARGS=--build-name=$name --build-number=$GITHUB_RUN_NUMBER"
