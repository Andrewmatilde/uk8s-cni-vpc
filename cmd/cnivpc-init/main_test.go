// Copyright UCloud. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License"). You may
// not use this file except in compliance with the License. A copy of the
// License is located at
//
// https://www.apache.org/licenses/LICENSE-2.0
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunWithPaths(t *testing.T) {
	const (
		sourceVersion = "ucloud-uk8s-cnivpc version 2.0.0-alpha.5"
		oldVersion    = "ucloud-uk8s-cnivpc version 1.2.0"
	)

	t.Run("installs the CNI binary when the target is missing", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		unsetEnv(t, envCNIInitOverwrite)

		if err := runWithPaths(sourcePath, targetPath); err != nil {
			t.Fatalf("runWithPaths() error = %v", err)
		}
		if got := readVersion(t, targetPath); got != sourceVersion {
			t.Fatalf("installed version = %q, want %q", got, sourceVersion)
		}
		if got, want := readFile(t, targetPath), readFile(t, sourcePath); got != want {
			t.Fatalf("installed binary does not match source")
		}
		info, err := os.Stat(targetPath)
		if err != nil {
			t.Fatalf("stat installed binary: %v", err)
		}
		if got, want := info.Mode().Perm(), os.FileMode(0o755); got != want {
			t.Fatalf("installed mode = %v, want %v", got, want)
		}
	})

	t.Run("leaves an existing binary with the same version unchanged", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		writeVersionBinary(t, targetPath, sourceVersion, "existing")
		t.Setenv(envCNIInitOverwrite, "true")
		before := readFile(t, targetPath)

		if err := runWithPaths(sourcePath, targetPath); err != nil {
			t.Fatalf("runWithPaths() error = %v", err)
		}
		if after := readFile(t, targetPath); after != before {
			t.Fatalf("same-version target was modified")
		}
	})

	t.Run("atomically replaces a binary with a different version when overwrite is enabled", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		writeVersionBinary(t, targetPath, oldVersion, "existing")
		t.Setenv(envCNIInitOverwrite, " true ")
		if err := os.WriteFile(targetPath+".tmp", []byte("stale"), 0o600); err != nil {
			t.Fatalf("write stale temporary target: %v", err)
		}

		if err := runWithPaths(sourcePath, targetPath); err != nil {
			t.Fatalf("runWithPaths() error = %v", err)
		}
		if got := readVersion(t, targetPath); got != sourceVersion {
			t.Fatalf("installed version = %q, want %q", got, sourceVersion)
		}
		if got, want := readFile(t, targetPath), readFile(t, sourcePath); got != want {
			t.Fatalf("replaced binary does not match source")
		}
		if _, err := os.Stat(targetPath + ".tmp"); !os.IsNotExist(err) {
			t.Fatalf("temporary target still exists: %v", err)
		}
	})

	t.Run("keeps a binary with a different version when overwrite is disabled", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		writeVersionBinary(t, targetPath, oldVersion, "existing")
		t.Setenv(envCNIInitOverwrite, "false")

		if err := runWithPaths(sourcePath, targetPath); err != nil {
			t.Fatalf("runWithPaths() error = %v", err)
		}
		if got := readVersion(t, targetPath); got != oldVersion {
			t.Fatalf("retained version = %q, want %q", got, oldVersion)
		}
	})

	t.Run("rejects an invalid overwrite mode", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		writeVersionBinary(t, targetPath, oldVersion, "existing")
		t.Setenv(envCNIInitOverwrite, "sometimes")

		err := runWithPaths(sourcePath, targetPath)
		if err == nil || !strings.Contains(err.Error(), "expected true or false") {
			t.Fatalf("runWithPaths() error = %v, want invalid mode error", err)
		}
	})

	t.Run("returns an error when the existing binary version cannot be read", func(t *testing.T) {
		sourcePath, targetPath := newTestPaths(t)
		writeVersionBinary(t, sourcePath, sourceVersion, "source")
		if err := os.WriteFile(targetPath, []byte("#!/bin/sh\nexit 2\n"), 0o755); err != nil {
			t.Fatalf("write invalid target: %v", err)
		}
		t.Setenv(envCNIInitOverwrite, "true")
		before := readFile(t, targetPath)

		err := runWithPaths(sourcePath, targetPath)
		if err == nil {
			t.Fatalf("runWithPaths() error = nil, want version probe error")
		}
		if after := readFile(t, targetPath); after != before {
			t.Fatalf("target was modified after a version probe error")
		}
	})
}

func newTestPaths(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	return filepath.Join(dir, "source-cnivpc"), filepath.Join(dir, "target-cnivpc")
}

func writeVersionBinary(t *testing.T, path, version, marker string) {
	t.Helper()
	content := fmt.Sprintf("#!/bin/sh\n[ \"$1\" = \"--version\" ] || exit 2\nprintf '%%s\\n' %q\n# %s\n", version, marker)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatalf("write executable %s: %v", path, err)
	}
}

func readVersion(t *testing.T, path string) string {
	t.Helper()
	output, err := exec.Command(path, "--version").CombinedOutput()
	if err != nil {
		t.Fatalf("execute %s: %v: %s", path, err, output)
	}
	return strings.TrimSpace(string(output))
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(contents)
}

func unsetEnv(t *testing.T, key string) {
	t.Helper()
	value, exists := os.LookupEnv(key)
	if err := os.Unsetenv(key); err != nil {
		t.Fatalf("unset %s: %v", key, err)
	}
	t.Cleanup(func() {
		if exists {
			if err := os.Setenv(key, value); err != nil {
				t.Errorf("restore %s: %v", key, err)
			}
			return
		}
		if err := os.Unsetenv(key); err != nil {
			t.Errorf("unset %s during cleanup: %v", key, err)
		}
	})
}
