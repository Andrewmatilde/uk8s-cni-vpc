package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"

	"github.com/cockroachdb/errors"
)

func copyFile(src, dst string) error {
	dstTmp := dst + ".tmp"
	if err := os.Remove(dstTmp); err != nil && !errors.Is(err, os.ErrNotExist) {
		return errors.Wrapf(err, "main.copyFile remove stale destination %s", errors.Safe(dstTmp))
	}
	if err := cp(src, dstTmp); err != nil {
		return err
	}
	if err := backupCNIBinary(dst); err != nil {
		return err
	}
	if err := os.Rename(dstTmp, dst); err != nil {
		return errors.Wrapf(err, "main.copyFile rename destination %s", errors.Safe(dst))
	}
	return nil
}

func backupCNIBinary(path string) error {
	digest, err := fileSHA256(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}

	backupPath := path + ".bak." + digest
	// cp uses O_EXCL: an existing backup is never overwritten, even on retry.
	if err := cp(path, backupPath); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	backupInfo, err := os.Lstat(backupPath)
	if err != nil {
		return errors.Wrapf(err, "main.backupCNIBinary stat %s", errors.Safe(backupPath))
	}
	if !backupInfo.Mode().IsRegular() {
		return errors.Errorf("main.backupCNIBinary backup %s is not a regular file", errors.Safe(backupPath))
	}
	backupDigest, err := fileSHA256(backupPath)
	if err != nil {
		return err
	}
	if backupDigest != digest {
		return errors.Errorf("main.backupCNIBinary checksum mismatch for %s", errors.Safe(backupPath))
	}
	fmt.Printf("CNI backup available at %s\n", backupPath)
	return nil
}

func fileSHA256(path string) (digest string, err error) {
	file, err := os.Open(path)
	if err != nil {
		return "", errors.Wrapf(err, "main.fileSHA256 open %s", errors.Safe(path))
	}
	defer func() {
		err = errors.CombineErrors(err, errors.Wrap(file.Close(), "main.fileSHA256 close"))
	}()

	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", errors.Wrap(err, "main.fileSHA256 hash")
	}
	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

func cp(src, dst string) (err error) {
	created := false
	defer func() {
		// Never leave a failed copy behind as a reusable backup.
		if err != nil && created {
			removeErr := os.Remove(dst)
			if !errors.Is(removeErr, os.ErrNotExist) {
				err = errors.CombineErrors(err, errors.Wrap(removeErr, "main.cp remove incomplete copy"))
			}
		}
	}()

	sourceFileInfo, err := os.Stat(src)
	if err != nil {
		return errors.Wrapf(err, "main.cp stat source %s", errors.Safe(src))
	}
	if !sourceFileInfo.Mode().IsRegular() {
		return errors.Errorf("main.cp source %s is not a regular file", errors.Safe(src))
	}

	source, err := os.Open(src)
	if err != nil {
		return errors.Wrapf(err, "main.cp open source %s", errors.Safe(src))
	}
	defer func() {
		err = errors.CombineErrors(err, errors.Wrap(source.Close(), "main.cp close source"))
	}()

	destination, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, sourceFileInfo.Mode().Perm())
	if err != nil {
		return errors.Wrapf(err, "main.cp create destination %s", errors.Safe(dst))
	}
	created = true
	defer func() {
		err = errors.CombineErrors(err, errors.Wrap(destination.Close(), "main.cp close destination"))
	}()

	if _, err := io.Copy(destination, source); err != nil {
		return errors.Wrap(err, "main.cp copy")
	}
	if err := destination.Sync(); err != nil {
		return errors.Wrap(err, "main.cp sync destination")
	}
	return nil
}
