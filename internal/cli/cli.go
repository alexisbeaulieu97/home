package cli

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"taxsend/internal/archive"
	"taxsend/internal/crypto"
	"taxsend/internal/fsutil"
	"taxsend/internal/output"
	"taxsend/internal/version"
)

type App struct {
	Out io.Writer
	Err io.Writer
}

func (a *App) Run(args []string) error {
	if len(args) == 0 {
		a.help()
		return nil
	}
	switch args[0] {
	case "help", "-h", "--help":
		a.help()
		return nil
	case "version":
		fmt.Fprintf(a.Out, "taxsend %s (%s)\n", version.Version, version.Commit)
		return nil
	case "keygen":
		return a.keygen(args[1:])
	case "recipient":
		return a.recipient(args[1:])
	case "encrypt":
		return a.encrypt(args[1:])
	case "decrypt":
		return a.decrypt(args[1:])
	case "inspect":
		return a.inspect(args[1:])
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}

func (a *App) help() {
	fmt.Fprintln(a.Out, `TaxSend bundles and encrypts tax documents for secure transport.

Commands:
  keygen      Generate an identity and recipient
  recipient   Print recipient for an identity file
  encrypt     Encrypt files/directories into a single .tar.age artifact
  decrypt     Decrypt artifact and extract tar contents
  inspect     Inspect artifact header
  version     Print version`)
}

func (a *App) keygen(args []string) error {
	fs := flag.NewFlagSet("keygen", flag.ContinueOnError)
	fs.SetOutput(a.Err)
	outPath := fs.String("output", filepath.Join(os.Getenv("HOME"), ".config", "taxsend", "identity.txt"), "identity output file")
	force := fs.Bool("force", false, "overwrite output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	id, recipient, err := crypto.GenerateIdentity()
	if err != nil {
		return err
	}
	f, err := fsutil.CreateFile(*outPath, *force, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	if _, err := fmt.Fprintln(f, id.String()); err != nil {
		return err
	}
	p := output.New(a.Out, a.Err, false)
	p.Info("identity written: %s", *outPath)
	p.Info("recipient: %s", recipient)
	p.Warn("store your identity file securely; losing it means losing access to encrypted artifacts")
	return nil
}

func loadIdentity(path string) (*crypto.Identity, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return crypto.ParseIdentity(string(b))
}

func (a *App) recipient(args []string) error {
	fs := flag.NewFlagSet("recipient", flag.ContinueOnError)
	fs.SetOutput(a.Err)
	idPath := fs.String("identity", "", "identity file path")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *idPath == "" {
		return errors.New("--identity is required")
	}
	id, err := loadIdentity(*idPath)
	if err != nil {
		return fmt.Errorf("invalid identity: %w", err)
	}
	rec, _ := id.RecipientString()
	fmt.Fprintln(a.Out, rec)
	return nil
}

func defaultArtifactName() string {
	return "bundle-" + time.Now().Format("20060102-150405") + ".tar.age"
}

func (a *App) encrypt(args []string) error {
	fs := flag.NewFlagSet("encrypt", flag.ContinueOnError)
	fs.SetOutput(a.Err)
	recStr := fs.String("recipient", "", "recipient string")
	outPath := fs.String("output", defaultArtifactName(), "output artifact path")
	force := fs.Bool("force", false, "overwrite output")
	verbose := fs.Bool("verbose", false, "verbose output")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *recStr == "" {
		return errors.New("--recipient is required")
	}
	rec, err := crypto.ParseRecipient(*recStr)
	if err != nil {
		return fmt.Errorf("invalid recipient: %w", err)
	}
	entries, err := archive.CollectEntries(fs.Args())
	if err != nil {
		return err
	}
	out, err := fsutil.CreateFile(*outPath, *force, 0o600)
	if err != nil {
		return err
	}
	defer out.Close()
	ew, err := crypto.EncryptWriter(out, rec)
	if err != nil {
		return err
	}
	if err := archive.WriteTar(ew, entries); err != nil {
		return err
	}
	if err := ew.Close(); err != nil {
		return err
	}
	p := output.New(a.Out, a.Err, *verbose)
	p.Info("encrypted %d files into %s", len(entries), *outPath)
	p.Info("recipient: %s", *recStr)
	p.Warn("metadata outside encrypted payload (artifact size/timestamp) remains visible")
	return nil
}

func (a *App) decrypt(args []string) error {
	fs := flag.NewFlagSet("decrypt", flag.ContinueOnError)
	fs.SetOutput(a.Err)
	idPath := fs.String("identity", "", "identity file path")
	outDir := fs.String("output-dir", ".", "extraction directory")
	force := fs.Bool("force", false, "overwrite extracted files")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *idPath == "" {
		return errors.New("--identity is required")
	}
	if fs.NArg() != 1 {
		return errors.New("decrypt requires exactly one artifact argument")
	}
	id, err := loadIdentity(*idPath)
	if err != nil {
		return fmt.Errorf("invalid identity: %w", err)
	}
	in, err := os.Open(fs.Arg(0))
	if err != nil {
		return err
	}
	defer in.Close()
	dr, err := crypto.DecryptReader(in, id)
	if err != nil {
		return err
	}
	count, err := archive.ExtractTar(dr, *outDir, *force)
	if err != nil {
		return err
	}
	fmt.Fprintf(a.Out, "decrypted and extracted %d files into %s\n", count, *outDir)
	return nil
}

func (a *App) inspect(args []string) error {
	if len(args) != 1 {
		return errors.New("inspect requires exactly one artifact path")
	}
	f, err := os.Open(args[0])
	if err != nil {
		return err
	}
	defer f.Close()
	h := make([]byte, 4)
	if _, err := io.ReadFull(f, h); err != nil {
		return err
	}
	if string(h) == "TS1\n" {
		fmt.Fprintf(a.Out, "artifact: taxsend-v1\npath: %s\n", args[0])
		return nil
	}
	return fmt.Errorf("file %s is not a recognized TaxSend artifact", args[0])
}

func ExplainDependencyLimit() string {
	return strings.TrimSpace("network access is restricted; external dependencies (cobra/age/charmbracelet-log) were unavailable")
}
