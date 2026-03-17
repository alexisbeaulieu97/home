package crypto

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

const (
	IdentityPrefix  = "TAXSEND-SECRET-KEY-"
	RecipientPrefix = "taxsend1"
)

type Identity struct{ key *ecdh.PrivateKey }
type Recipient struct{ key *ecdh.PublicKey }

func GenerateIdentity() (*Identity, string, error) {
	priv, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, "", err
	}
	id := &Identity{key: priv}
	rec, _ := id.RecipientString()
	return id, rec, nil
}

func (i *Identity) String() string {
	return IdentityPrefix + base64.StdEncoding.EncodeToString(i.key.Bytes())
}

func ParseIdentity(s string) (*Identity, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, IdentityPrefix) {
		return nil, errors.New("invalid identity prefix")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(s, IdentityPrefix))
	if err != nil {
		return nil, err
	}
	k, err := ecdh.X25519().NewPrivateKey(raw)
	if err != nil {
		return nil, err
	}
	return &Identity{key: k}, nil
}

func ParseRecipient(s string) (*Recipient, error) {
	s = strings.TrimSpace(s)
	if !strings.HasPrefix(s, RecipientPrefix) {
		return nil, errors.New("invalid recipient prefix")
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(s, RecipientPrefix))
	if err != nil {
		return nil, err
	}
	k, err := ecdh.X25519().NewPublicKey(raw)
	if err != nil {
		return nil, err
	}
	return &Recipient{key: k}, nil
}

func (i *Identity) RecipientString() (string, error) {
	return RecipientPrefix + base64.StdEncoding.EncodeToString(i.key.PublicKey().Bytes()), nil
}

type encryptWriter struct {
	w       io.Writer
	gcm     cipher.AEAD
	prefix  []byte
	counter uint64
}

func nonce(prefix []byte, ctr uint64) []byte {
	n := make([]byte, 12)
	copy(n, prefix)
	binary.BigEndian.PutUint64(n[4:], ctr)
	return n
}

func (e *encryptWriter) Write(p []byte) (int, error) {
	off := 0
	for off < len(p) {
		chunkEnd := off + 64*1024
		if chunkEnd > len(p) {
			chunkEnd = len(p)
		}
		chunk := p[off:chunkEnd]
		sealed := e.gcm.Seal(nil, nonce(e.prefix, e.counter), chunk, nil)
		e.counter++
		var lenBuf [4]byte
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(sealed)))
		if _, err := e.w.Write(lenBuf[:]); err != nil {
			return off, err
		}
		if _, err := e.w.Write(sealed); err != nil {
			return off, err
		}
		off = chunkEnd
	}
	return len(p), nil
}

func EncryptWriter(w io.Writer, recipient *Recipient) (io.WriteCloser, error) {
	eph, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	shared, err := eph.ECDH(recipient.key)
	if err != nil {
		return nil, err
	}
	k := sha256.Sum256(shared)
	block, err := aes.NewCipher(k[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	prefix := make([]byte, 4)
	if _, err := rand.Read(prefix); err != nil {
		return nil, err
	}
	if _, err := w.Write([]byte("TS1\n")); err != nil {
		return nil, err
	}
	if _, err := w.Write(eph.PublicKey().Bytes()); err != nil {
		return nil, err
	}
	if _, err := w.Write(prefix); err != nil {
		return nil, err
	}
	return nopCloser{&encryptWriter{w: w, gcm: gcm, prefix: prefix}}, nil
}

type decryptReader struct {
	r       io.Reader
	gcm     cipher.AEAD
	prefix  []byte
	counter uint64
	buf     []byte
}

func (d *decryptReader) Read(p []byte) (int, error) {
	if len(d.buf) == 0 {
		var lenBuf [4]byte
		if _, err := io.ReadFull(d.r, lenBuf[:]); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return 0, io.EOF
			}
			return 0, err
		}
		cl := binary.BigEndian.Uint32(lenBuf[:])
		cipherChunk := make([]byte, cl)
		if _, err := io.ReadFull(d.r, cipherChunk); err != nil {
			return 0, err
		}
		plain, err := d.gcm.Open(nil, nonce(d.prefix, d.counter), cipherChunk, nil)
		if err != nil {
			return 0, fmt.Errorf("decrypt chunk: %w", err)
		}
		d.counter++
		d.buf = plain
	}
	n := copy(p, d.buf)
	d.buf = d.buf[n:]
	return n, nil
}

func DecryptReader(r io.Reader, identity *Identity) (io.Reader, error) {
	h := make([]byte, 4)
	if _, err := io.ReadFull(r, h); err != nil {
		return nil, err
	}
	if string(h) != "TS1\n" {
		return nil, errors.New("invalid artifact format")
	}
	eph := make([]byte, 32)
	if _, err := io.ReadFull(r, eph); err != nil {
		return nil, err
	}
	prefix := make([]byte, 4)
	if _, err := io.ReadFull(r, prefix); err != nil {
		return nil, err
	}
	pub, err := ecdh.X25519().NewPublicKey(eph)
	if err != nil {
		return nil, err
	}
	shared, err := identity.key.ECDH(pub)
	if err != nil {
		return nil, err
	}
	k := sha256.Sum256(shared)
	block, err := aes.NewCipher(k[:])
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	return &decryptReader{r: r, gcm: gcm, prefix: prefix}, nil
}

type nopCloser struct{ io.Writer }

func (n nopCloser) Close() error { return nil }
