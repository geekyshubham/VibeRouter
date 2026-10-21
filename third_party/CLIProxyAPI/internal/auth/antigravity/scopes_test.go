package antigravity

import (
	"net/url"
	"strings"
	"testing"
)

func TestBuildAuthURLRequestsScopesTheACPServerRenewsWith(t *testing.T) {
	parsed, err := url.Parse(NewAntigravityAuth(nil, nil).BuildAuthURL("state", ""))
	if err != nil {
		t.Fatalf("parse auth URL: %v", err)
	}
	granted := strings.Fields(parsed.Query().Get("scope"))
	for _, want := range []string{
		"https://www.googleapis.com/auth/cloud-platform",
		"https://www.googleapis.com/auth/userinfo.email",
		"https://www.googleapis.com/auth/aicode",
	} {
		found := false
		for _, scope := range granted {
			found = found || scope == want
		}
		if !found {
			t.Errorf("auth URL scope %q missing; agy ACP refresh would fail", want)
		}
	}
}
