package server

import (
	"testing"

	"github.com/ollama/ollama/api"
)

func TestWithDefaultEmbeddingNumCtx(t *testing.T) {
	t.Run("adds conservative default when missing", func(t *testing.T) {
		original := map[string]any{"num_batch": int64(512)}

		got := withDefaultEmbeddingNumCtx(original)

		if _, ok := original["num_ctx"]; ok {
			t.Fatalf("original options map was mutated: %#v", original)
		}

		if got["num_ctx"] != int64(defaultEmbeddingNumCtx) {
			t.Fatalf("num_ctx = %v, want %d", got["num_ctx"], defaultEmbeddingNumCtx)
		}

		if got["num_batch"] != int64(512) {
			t.Fatalf("num_batch = %v, want 512", got["num_batch"])
		}

		var opts api.Options
		if err := opts.FromMap(got); err != nil {
			t.Fatalf("FromMap() error = %v", err)
		}

		if opts.NumCtx != defaultEmbeddingNumCtx {
			t.Fatalf("parsed num_ctx = %d, want %d", opts.NumCtx, defaultEmbeddingNumCtx)
		}
	})

	t.Run("preserves explicit num_ctx", func(t *testing.T) {
		original := map[string]any{"num_ctx": int64(8192), "num_batch": int64(256)}

		got := withDefaultEmbeddingNumCtx(original)

		if got["num_ctx"] != int64(8192) {
			t.Fatalf("num_ctx = %v, want 8192", got["num_ctx"])
		}

		if got["num_batch"] != int64(256) {
			t.Fatalf("num_batch = %v, want 256", got["num_batch"])
		}
	})
}
