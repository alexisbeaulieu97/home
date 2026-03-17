package output

import (
	"fmt"
	"io"
)

type Printer struct {
	out     io.Writer
	err     io.Writer
	verbose bool
}

func New(out, err io.Writer, verbose bool) *Printer {
	return &Printer{out: out, err: err, verbose: verbose}
}

func (p *Printer) Info(format string, args ...any) {
	fmt.Fprintf(p.out, format+"\n", args...)
}

func (p *Printer) Warn(format string, args ...any) {
	fmt.Fprintf(p.err, "warning: "+format+"\n", args...)
}

func (p *Printer) Verbose(format string, args ...any) {
	if p.verbose {
		fmt.Fprintf(p.out, format+"\n", args...)
	}
}
