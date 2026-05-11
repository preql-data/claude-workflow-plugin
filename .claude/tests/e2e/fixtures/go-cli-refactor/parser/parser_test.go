// Tests for the parser package. After the refactor these tests should
// move with the package and continue to pass under the new import path.
package parser

import "testing"

func TestParse_OK(t *testing.T) {
	tokens, err := Parse("hello world from go")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := []string{"hello", "world", "from", "go"}
	if len(tokens) != len(want) {
		t.Fatalf("expected %d tokens, got %d", len(want), len(tokens))
	}
	for i, w := range want {
		if tokens[i] != w {
			t.Errorf("tokens[%d] = %q, want %q", i, tokens[i], w)
		}
	}
}

func TestParse_Empty(t *testing.T) {
	if _, err := Parse("   "); err == nil {
		t.Fatal("expected error on empty input")
	}
}
