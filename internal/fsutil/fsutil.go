package fsutil

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

func EnsureNotExists(path string, force bool) error {
	_, err := os.Stat(path)
	if err == nil && !force {
		return fmt.Errorf("refusing to overwrite existing path %q (use --force)", path)
	}
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func CreateFile(path string, force bool, perm os.FileMode) (*os.File, error) {
	if err := EnsureNotExists(path, force); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, err
	}
	flags := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	return os.OpenFile(path, flags, perm)
}
