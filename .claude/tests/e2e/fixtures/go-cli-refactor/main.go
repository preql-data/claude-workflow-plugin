// Entry point for the example CLI.
//
// This file imports github.com/example/cli/parser. The fixture's prompt
// asks Claude to extract that package into internal/parser/ — a refactor
// that requires updating the import below to match the new path
// (e.g. github.com/example/cli/internal/parser). If the orchestrator
// moves the directory but forgets to update main.go, `go build` fails
// and QA's regression-coverage check (J19) blocks approval.
package main

import (
	"fmt"
	"os"

	"github.com/example/cli/parser"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: cli <expr>")
		os.Exit(2)
	}
	tokens, err := parser.Parse(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "parse error:", err)
		os.Exit(1)
	}
	fmt.Println("tokens:", tokens)
}
