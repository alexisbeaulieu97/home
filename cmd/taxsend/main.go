package main

import (
	"fmt"
	"os"

	"taxsend/internal/cli"
)

func main() {
	app := &cli.App{Out: os.Stdout, Err: os.Stderr}
	if err := app.Run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}
