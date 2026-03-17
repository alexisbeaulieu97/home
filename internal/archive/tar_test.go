package archive

import (
	"archive/tar"
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func TestExtractTarRejectsTraversal(t *testing.T) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: "../../evil.txt", Mode: 0o600, Size: 1, Typeflag: tar.TypeReg})
	_, _ = tw.Write([]byte("x"))
	_ = tw.Close()
	_, err := ExtractTar(bytes.NewReader(buf.Bytes()), t.TempDir(), false)
	if err == nil {
		t.Fatal("expected traversal error")
	}
}

func TestExtractTarNoOverwriteWithoutForce(t *testing.T) {
	out := t.TempDir()
	target := filepath.Join(out, "a.txt")
	if err := os.WriteFile(target, []byte("old"), 0o600); err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	_ = tw.WriteHeader(&tar.Header{Name: "a.txt", Mode: 0o600, Size: 3, Typeflag: tar.TypeReg})
	_, _ = tw.Write([]byte("new"))
	_ = tw.Close()
	_, err := ExtractTar(bytes.NewReader(buf.Bytes()), out, false)
	if err == nil {
		t.Fatal("expected overwrite refusal")
	}
}
