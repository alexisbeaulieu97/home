package archive

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

type FileEntry struct {
	AbsPath string
	TarPath string
	Info    fs.FileInfo
}

func CollectEntries(inputs []string) ([]FileEntry, error) {
	if len(inputs) == 0 {
		return nil, errors.New("no input files provided")
	}
	var entries []FileEntry
	for _, in := range inputs {
		clean := filepath.Clean(in)
		st, err := os.Stat(clean)
		if err != nil {
			return nil, fmt.Errorf("stat %q: %w", in, err)
		}
		base := filepath.Base(clean)
		if st.IsDir() {
			err = filepath.WalkDir(clean, func(path string, d fs.DirEntry, walkErr error) error {
				if walkErr != nil {
					return walkErr
				}
				if d.IsDir() {
					return nil
				}
				info, err := d.Info()
				if err != nil {
					return err
				}
				rel, err := filepath.Rel(clean, path)
				if err != nil {
					return err
				}
				tarPath := filepath.ToSlash(filepath.Join(base, rel))
				entries = append(entries, FileEntry{AbsPath: path, TarPath: tarPath, Info: info})
				return nil
			})
			if err != nil {
				return nil, fmt.Errorf("walk %q: %w", in, err)
			}
			continue
		}
		entries = append(entries, FileEntry{AbsPath: clean, TarPath: filepath.ToSlash(base), Info: st})
	}
	if len(entries) == 0 {
		return nil, errors.New("no regular files discovered in provided inputs")
	}
	return entries, nil
}

func WriteTar(w io.Writer, entries []FileEntry) error {
	tw := tar.NewWriter(w)
	defer tw.Close()
	for _, e := range entries {
		hdr, err := tar.FileInfoHeader(e.Info, "")
		if err != nil {
			return err
		}
		hdr.Name = e.TarPath
		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		f, err := os.Open(e.AbsPath)
		if err != nil {
			return err
		}
		_, copyErr := io.Copy(tw, f)
		closeErr := f.Close()
		if copyErr != nil {
			return copyErr
		}
		if closeErr != nil {
			return closeErr
		}
	}
	return nil
}

func safeJoin(root, name string) (string, error) {
	clean := filepath.Clean(name)
	if clean == "." || clean == "" {
		return "", errors.New("empty tar entry")
	}
	if strings.HasPrefix(clean, "../") || clean == ".." || filepath.IsAbs(clean) {
		return "", fmt.Errorf("unsafe tar path %q", name)
	}
	full := filepath.Join(root, clean)
	rel, err := filepath.Rel(root, full)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("unsafe tar path %q", name)
	}
	return full, nil
}

func ExtractTar(r io.Reader, outputDir string, force bool) (int, error) {
	tr := tar.NewReader(r)
	count := 0
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return count, err
		}
		if hdr.Typeflag != tar.TypeReg {
			continue
		}
		target, err := safeJoin(outputDir, hdr.Name)
		if err != nil {
			return count, err
		}
		if !force {
			if _, err := os.Stat(target); err == nil {
				return count, fmt.Errorf("refusing to overwrite %q (use --force)", target)
			} else if !errors.Is(err, os.ErrNotExist) {
				return count, err
			}
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return count, err
		}
		f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(hdr.Mode))
		if err != nil {
			return count, err
		}
		_, copyErr := io.Copy(f, tr)
		closeErr := f.Close()
		if copyErr != nil {
			return count, copyErr
		}
		if closeErr != nil {
			return count, closeErr
		}
		count++
	}
	return count, nil
}
