#!/bin/bash
set -euo pipefail
AGY_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec /bin/bash "$AGY_PROJECT/scripts/build-intel.sh"
