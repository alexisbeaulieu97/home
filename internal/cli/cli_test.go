package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEndToEndFlow(t *testing.T) {
	tmp := t.TempDir()
	home := filepath.Join(tmp, "home")
	if err := os.MkdirAll(home, 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	input := filepath.Join(tmp, "T4.txt")
	if err := os.WriteFile(input, []byte("sensitive"), 0o600); err != nil {
		t.Fatal(err)
	}

	out := &bytes.Buffer{}
	errOut := &bytes.Buffer{}
	app := &App{Out: out, Err: errOut}
	idPath := filepath.Join(tmp, "id.txt")
	if err := app.Run([]string{"keygen", "--output", idPath}); err != nil {
		t.Fatal(err)
	}
	rec := ""
	for _, line := range strings.Split(out.String(), "\n") {
		if strings.HasPrefix(line, "recipient: ") {
			rec = strings.TrimPrefix(line, "recipient: ")
		}
	}
	if rec == "" {
		t.Fatal("recipient missing")
	}
	artifact := filepath.Join(tmp, "docs.tar.age")
	if err := app.Run([]string{"encrypt", "--recipient", rec, "--output", artifact, input}); err != nil {
		t.Fatal(err)
	}
	if err := app.Run([]string{"inspect", artifact}); err != nil {
		t.Fatal(err)
	}
	outDir := filepath.Join(tmp, "out")
	if err := app.Run([]string{"decrypt", "--identity", idPath, "--output-dir", outDir, artifact}); err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile(filepath.Join(outDir, "T4.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != "sensitive" {
		t.Fatalf("unexpected content %q", got)
	}
}
