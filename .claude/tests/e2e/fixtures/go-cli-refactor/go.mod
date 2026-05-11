module github.com/example/cli

// G8 Phase C fixture #3: minimal Go CLI module.
//
// The fixture's parser/ directory currently lives at the module root and
// is imported by main.go as "github.com/example/cli/parser". The prompt
// asks Claude to extract parser/ into internal/parser/ — a refactor that
// changes the import path. Because main.go also calls parser.Parse(),
// failing to update the caller import (or any other call sites) would
// be caught by QA's regression-coverage check (J19): the binary would
// no longer build.

go 1.22
