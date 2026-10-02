package management

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/router-for-me/CLIProxyAPI/v7/internal/config"
	coreauth "github.com/router-for-me/CLIProxyAPI/v7/sdk/cliproxy/auth"
)

func TestListAuthFilesSkipsBookkeepingOnDiskAndInMemory(t *testing.T) {
	for _, inMemory := range []bool{false, true} {
		t.Run(map[bool]string{false: "disk", true: "memory"}[inMemory], func(t *testing.T) {
			dir := t.TempDir()
			var manager *coreauth.Manager
			if inMemory {
				manager = coreauth.NewManager(nil, nil, nil)
			}
			for _, name := range []string{".viberouter-deleted-seats.json", "codex-test.json"} {
				path := filepath.Join(dir, name)
				if err := os.WriteFile(path, []byte(`{"type":"codex"}`), 0o600); err != nil {
					t.Fatal(err)
				}
				if manager != nil {
					_, err := manager.Register(context.Background(), &coreauth.Auth{ID: name, FileName: name, Provider: "codex", Attributes: map[string]string{"path": path}})
					if err != nil {
						t.Fatal(err)
					}
				}
			}
			h := NewHandlerWithoutConfigFilePath(&config.Config{AuthDir: dir}, manager)
			rec := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(rec)
			c.Request = httptest.NewRequest(http.MethodGet, "/auth-files", nil)
			h.ListAuthFiles(c)
			var data struct {
				Files []struct {
					Name string `json:"name"`
				} `json:"files"`
			}
			if err := json.Unmarshal(rec.Body.Bytes(), &data); err != nil {
				t.Fatal(err)
			}
			if rec.Code != 200 || len(data.Files) != 1 || data.Files[0].Name != "codex-test.json" {
				t.Fatalf("bookkeeping in accounts: %s", rec.Body.String())
			}
		})
	}
}
