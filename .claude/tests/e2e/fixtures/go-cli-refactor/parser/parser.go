// Package parser tokenizes a small expression grammar for the example CLI.
//
// Today this package lives at the module root. The fixture's prompt asks
// Claude to relocate it to internal/parser/ as part of a project-layout
// cleanup. The Parse function is exported and called from main.go.
package parser

import (
	"fmt"
	"strings"
)

// Parse splits the input into whitespace-separated tokens, returning an
// error if the input is empty.
func Parse(input string) ([]string, error) {
	if strings.TrimSpace(input) == "" {
		return nil, fmt.Errorf("empty input")
	}
	return strings.Fields(input), nil
}
