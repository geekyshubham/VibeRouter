package auth

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func TestFileTokenStoreSkipsBookkeeping(t *testing.T) {
	dir := t.TempDir()
	for name, data := range map[string]string{
		".viberouter-deleted-seats.json": `{"deleted":[]}`,
		".vibeproxy-deleted-seats.json":  `{"type":"codex"}`,
		"notes.json":                     `{"note":"not a credential"}`,
		"codex-test.json":                `{"type":"codex","email":"test@example.com"}`,
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	store := NewFileTokenStore()
	store.SetBaseDir(dir)
	auths, err := store.List(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if len(auths) != 1 || auths[0].FileName != "codex-test.json" {
		t.Fatalf("bookkeeping loaded as accounts: %+v", auths)
	}
}
