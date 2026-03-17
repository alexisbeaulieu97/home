package crypto

import (
	"bytes"
	"io"
	"testing"
)

func TestEncryptDecryptRoundTrip(t *testing.T) {
	id, rec, err := GenerateIdentity()
	if err != nil {
		t.Fatal(err)
	}
	r, err := ParseRecipient(rec)
	if err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	ew, err := EncryptWriter(&out, r)
	if err != nil {
		t.Fatal(err)
	}
	plain := bytes.Repeat([]byte("taxdoc"), 20000)
	if _, err := ew.Write(plain); err != nil {
		t.Fatal(err)
	}
	if err := ew.Close(); err != nil {
		t.Fatal(err)
	}

	dr, err := DecryptReader(bytes.NewReader(out.Bytes()), id)
	if err != nil {
		t.Fatal(err)
	}
	got, err := io.ReadAll(dr)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatal("plaintext mismatch")
	}
}
