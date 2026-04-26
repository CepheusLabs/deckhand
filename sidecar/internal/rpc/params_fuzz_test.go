package rpc

import (
	"encoding/json"
	"testing"
)

// FuzzValidateParams feeds arbitrary bytes into ValidateParams. The
// contract we exercise is narrow but load-bearing: the function must
// never panic, and when it does return an error it must always be a
// typed `*Error` — a plain `error` would skip the RPC boundary's
// error-code mapping and surface to the UI as a generic internal
// failure.
//
// Seed corpus covers the shapes we hand-authored tests for plus a
// handful of edge cases (deep nesting, duplicate keys, unicode
// surrogates) that wire-protocol clients sometimes produce.
func FuzzValidateParams(f *testing.F) {
	seeds := []string{
		`{}`,
		`{"x":"hi"}`,
		`{"x":null}`,
		`{"x":42}`,
		`{"x":"\u0000"}`,
		`{"x":true,"y":false}`,
		`{"arr":[1,2,3]}`,
		`{"nested":{"k":"v"}}`,
		`null`,
		``,
		`[1,2,3]`,                                // array at root — invalid
		`{"x":{"x":{"x":{"x":{"x":{}}}}}}`,       // nested deeper
		`{"\uD83D":"x"}`,                         // lone high surrogate
		`{"big":123456789012345678901234567890}`, // number too big for int64
	}
	for _, s := range seeds {
		f.Add(s)
	}

	specs := []ParamSpec{
		{Name: "x", Required: false, Kind: ParamKindString, MinLen: 0, MaxLen: 256},
		{Name: "y", Required: false, Kind: ParamKindBool},
		{Name: "arr", Required: false, Kind: ParamKindArray, MinLen: 0, MaxLen: 1024},
		{Name: "nested", Required: false, Kind: ParamKindObject},
		{Name: "big", Required: false, Kind: ParamKindInt},
	}

	f.Fuzz(func(t *testing.T, raw string) {
		err := ValidateParams(json.RawMessage(raw), specs)
		if err == nil {
			return
		}
		// Contract: every error MUST be a typed *rpc.Error.
		if _, ok := err.(*Error); !ok {
			t.Fatalf("ValidateParams returned non-*Error type %T for input %q: %v",
				err, raw, err)
		}
	})
}

// FuzzValidateParams_PatternCaching guards the regex-cache fast path.
// A handler that registered a bad pattern once must not wedge the
// cache or crash subsequent calls with valid patterns.
func FuzzValidateParams_PatternCaching(f *testing.F) {
	f.Add(`^[a-z]+$`, "hello")
	f.Add(`(unclosed`, "hello")
	f.Add(`^\d+$`, "42")
	f.Add(`.`, "")
	f.Fuzz(func(t *testing.T, pattern, value string) {
		// Skip inputs that would trivially break JSON encoding of the
		// value itself — fuzz is about ValidateParams, not json.Marshal.
		rawValue, err := json.Marshal(value)
		if err != nil {
			t.Skip()
		}
		params := json.RawMessage(`{"x":` + string(rawValue) + `}`)
		specs := []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, Pattern: pattern}}

		err = ValidateParams(params, specs)
		if err == nil {
			return
		}
		if _, ok := err.(*Error); !ok {
			t.Fatalf("ValidateParams returned non-*Error type %T for pattern=%q value=%q: %v",
				err, pattern, value, err)
		}
	})
}
