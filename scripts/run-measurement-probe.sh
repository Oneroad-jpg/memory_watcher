#!/bin/zsh

emulate -L zsh
set -euo pipefail

readonly PROJECT_ROOT="${0:A:h:h}"
readonly SAMPLE_COUNT="${1:-121}"

[[ "${SAMPLE_COUNT}" == <-> ]] || {
    print -u2 -- "sample count must be a positive integer"
    exit 2
}
(( SAMPLE_COUNT >= 1 && SAMPLE_COUNT <= 10000 )) || {
    print -u2 -- "sample count must be between 1 and 10000"
    exit 2
}

exec /usr/bin/swift run \
    --package-path "${PROJECT_ROOT}" \
    MemoryWatcherProbe \
    --samples "${SAMPLE_COUNT}"
