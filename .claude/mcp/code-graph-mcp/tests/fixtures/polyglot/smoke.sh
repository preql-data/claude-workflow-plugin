#!/bin/bash
# smoke.sh — Bash definition smoke.

smoke_fn() {
    echo "smoke"
}

main() {
    smoke_fn
}

main "$@"
