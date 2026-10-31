#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
export PATH="/opt/conduit-ponyc-0.77.2/bin:/opt/conduit-corral-0.9.2/bin:$PATH"
corral fetch
mkdir -p bin
corral run -- ponyc -D openssl_3.0.x --output bin --bin-name conduit conduit
corral run -- ponyc -D openssl_3.0.x --output bin --bin-name unit-tests tests
bin/unit-tests
