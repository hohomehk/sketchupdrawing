#!/bin/bash
# Run plugin unit tests via Docker (no Ruby needed on host).
set -e
cd "$(dirname "$0")/.."
docker run --rm -v "$PWD:/work" -w /work ruby:3.2-slim ruby tests/test_su_gpt_render.rb "$@"
