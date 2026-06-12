// main.go — Go fixture with known def/call shape.
//
// Defs: main, runTask, doWork, helperFunc, Counter (struct), Inc (method).
// Calls: main -> runTask -> doWork -> helperFunc; main -> (Counter).Inc.

package main

import "fmt"

type Counter struct {
	N int
}

func (c *Counter) Inc() {
	c.N++
}

func helperFunc() string {
	return "helped"
}

func doWork() string {
	return helperFunc()
}

func runTask() string {
	return doWork()
}

func main() {
	c := &Counter{}
	c.Inc()
	result := runTask()
	fmt.Println(result, c.N)
}
