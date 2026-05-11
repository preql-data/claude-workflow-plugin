// Smoke test for the main package. Verifies parser.Parse is reachable
// from this caller. After the refactor the import path changes but the
// behavior must remain — this test guards that path.
package main

import (
	"testing"

	"github.com/example/cli/parser"
)

func TestMain_ParserReachable(t *testing.T) {
	got, err := parser.Parse("a b c")
	if err != nil {
		t.Fatalf("Parse: unexpected error: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("expected 3 tokens, got %d", len(got))
	}
}
