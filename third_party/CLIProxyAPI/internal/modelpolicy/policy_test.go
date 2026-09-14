package modelpolicy

import (
	"reflect"
	"testing"
)

func reset(t *testing.T, p *Policy) {
	t.Helper()
	Set(p)
	t.Cleanup(func() { Set(&Policy{}) })
}

func TestIsDisabled(t *testing.T) {
	reset(t, &Policy{DisabledModels: []string{"gpt-5.5", "Kiro/Auto"}})

	if !IsDisabled("gpt-5.5") {
		t.Fatal("expected gpt-5.5 to be disabled")
	}
	if !IsDisabled("  GPT-5.5  ") {
		t.Fatal("expected case/whitespace-insensitive match")
	}
	if !IsDisabled("kiro/auto") {
		t.Fatal("expected kiro/auto disabled")
	}
	if IsDisabled("gpt-5.6-luna") {
		t.Fatal("did not expect unrelated model disabled")
	}
	if IsDisabled("") {
		t.Fatal("empty model id must never be reported disabled")
	}
}

func TestPriorityPosition(t *testing.T) {
	reset(t, &Policy{ModelPriority: []string{"a", "b"}})

	if pos, ok := PriorityPosition("b"); !ok || pos != 1 {
		t.Fatalf("expected b at position 1, got pos=%d ok=%v", pos, ok)
	}
	if pos, ok := PriorityPosition(" A "); !ok || pos != 0 {
		t.Fatalf("expected normalized a at 0, got pos=%d ok=%v", pos, ok)
	}
	if _, ok := PriorityPosition("zzz"); ok {
		t.Fatal("unlisted model must not be prioritized")
	}
}

func TestFallbackCandidates(t *testing.T) {
	reset(t, &Policy{
		ModelPriority:  []string{"first", "second", "third", "second", "disabled", ""},
		DisabledModels: []string{"disabled"},
	})

	got := FallbackCandidates("first", 0)
	want := []string{"second", "third"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("candidates = %v, want %v", got, want)
	}

	limited := FallbackCandidates("first", 1)
	if !reflect.DeepEqual(limited, []string{"second"}) {
		t.Fatalf("limited candidates = %v, want [second]", limited)
	}

	// For an unlisted requested model, every enabled priority entry qualifies.
	unlisted := FallbackCandidates("missing", 0)
	if !reflect.DeepEqual(unlisted, []string{"first", "second", "third"}) {
		t.Fatalf("candidates for unlisted model = %v", unlisted)
	}
}

func TestFallbackCandidatesNormalizesRequested(t *testing.T) {
	reset(t, &Policy{ModelPriority: []string{"Model-A", "model-b"}})

	got := FallbackCandidates("model-a", 0)
	if !reflect.DeepEqual(got, []string{"model-b"}) {
		t.Fatalf("candidates = %v, want [model-b]", got)
	}
}

func TestSetNilPolicyYieldsSafeDefault(t *testing.T) {
	Set(nil)
	defer Set(&Policy{})

	if Get() == nil {
		t.Fatal("Get() must never return nil")
	}
	if IsDisabled("anything") {
		t.Fatal("empty policy disables nothing")
	}
	if len(FallbackCandidates("x", 5)) != 0 {
		t.Fatal("empty policy yields no fallback candidates")
	}
}
