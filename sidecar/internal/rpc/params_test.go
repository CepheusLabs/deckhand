package rpc

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestValidateParams(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		specs   []ParamSpec
		wantErr bool
		wantMsg string // substring
	}{
		{
			name:  "all optional missing ok",
			raw:   `{}`,
			specs: []ParamSpec{{Name: "x", Kind: ParamKindString}},
		},
		{
			name:    "required missing",
			raw:     `{}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
			wantErr: true,
			wantMsg: `missing required param "x"`,
		},
		{
			name:    "required null is missing",
			raw:     `{"x":null}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
			wantErr: true,
			wantMsg: `missing required param "x"`,
		},
		{
			name:  "string ok",
			raw:   `{"x":"hello"}`,
			specs: []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
		},
		{
			name:    "string wrong type",
			raw:     `{"x":123}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
			wantErr: true,
			wantMsg: `must be a string`,
		},
		{
			name:    "string min len",
			raw:     `{"x":"hi"}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, MinLen: 3}},
			wantErr: true,
			wantMsg: `shorter than min length`,
		},
		{
			name:    "string max len",
			raw:     `{"x":"way too long"}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, MaxLen: 5}},
			wantErr: true,
			wantMsg: `exceeds max length`,
		},
		{
			name:  "string pattern match",
			raw:   `{"x":"abc123"}`,
			specs: []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, Pattern: `^[a-z0-9]+$`}},
		},
		{
			name:    "string pattern mismatch",
			raw:     `{"x":"ABC!!"}`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, Pattern: `^[a-z0-9]+$`}},
			wantErr: true,
			wantMsg: `does not match pattern`,
		},
		{
			name:  "int ok",
			raw:   `{"n":42}`,
			specs: []ParamSpec{{Name: "n", Required: true, Kind: ParamKindInt}},
		},
		{
			name:    "int rejects float",
			raw:     `{"n":3.14}`,
			specs:   []ParamSpec{{Name: "n", Required: true, Kind: ParamKindInt}},
			wantErr: true,
			wantMsg: `must be a int`,
		},
		{
			name:    "int rejects string",
			raw:     `{"n":"42"}`,
			specs:   []ParamSpec{{Name: "n", Required: true, Kind: ParamKindInt}},
			wantErr: true,
			wantMsg: `must be a int`,
		},
		{
			name:  "bool ok",
			raw:   `{"b":true}`,
			specs: []ParamSpec{{Name: "b", Required: true, Kind: ParamKindBool}},
		},
		{
			name:    "bool rejects number",
			raw:     `{"b":1}`,
			specs:   []ParamSpec{{Name: "b", Required: true, Kind: ParamKindBool}},
			wantErr: true,
			wantMsg: `must be a bool`,
		},
		{
			name:  "object ok",
			raw:   `{"o":{"k":"v"}}`,
			specs: []ParamSpec{{Name: "o", Required: true, Kind: ParamKindObject}},
		},
		{
			name:    "object rejects array",
			raw:     `{"o":[1,2]}`,
			specs:   []ParamSpec{{Name: "o", Required: true, Kind: ParamKindObject}},
			wantErr: true,
			wantMsg: `must be a object`,
		},
		{
			name:  "array ok",
			raw:   `{"a":[1,2,3]}`,
			specs: []ParamSpec{{Name: "a", Required: true, Kind: ParamKindArray}},
		},
		{
			name:    "array min len",
			raw:     `{"a":[1]}`,
			specs:   []ParamSpec{{Name: "a", Required: true, Kind: ParamKindArray, MinLen: 2}},
			wantErr: true,
			wantMsg: `fewer than 2 items`,
		},
		{
			name:    "array max len",
			raw:     `{"a":[1,2,3,4]}`,
			specs:   []ParamSpec{{Name: "a", Required: true, Kind: ParamKindArray, MaxLen: 2}},
			wantErr: true,
			wantMsg: `more than 2 items`,
		},
		{
			name:    "params not an object",
			raw:     `[1,2,3]`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
			wantErr: true,
			wantMsg: `params must be a JSON object`,
		},
		{
			name:    "null raw with required fails",
			raw:     `null`,
			specs:   []ParamSpec{{Name: "x", Required: true, Kind: ParamKindString}},
			wantErr: true,
			wantMsg: `missing required param`,
		},
		{
			name:  "empty raw with no required passes",
			raw:   ``,
			specs: []ParamSpec{{Name: "x", Kind: ParamKindString}},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateParams(json.RawMessage(tt.raw), tt.specs)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("expected error, got nil")
				}
				var rpcErr *Error
				if !errors.As(err, &rpcErr) {
					t.Fatalf("expected *Error, got %T", err)
				}
				if rpcErr.Code != codeInvalidParams {
					t.Fatalf("expected code %d (invalid params), got %d", codeInvalidParams, rpcErr.Code)
				}
				if tt.wantMsg != "" && !strings.Contains(rpcErr.Message, tt.wantMsg) {
					t.Fatalf("expected message to contain %q, got %q", tt.wantMsg, rpcErr.Message)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
		})
	}
}

func TestValidateParams_BadRegexSurfacesAsInternal(t *testing.T) {
	err := ValidateParams(
		json.RawMessage(`{"x":"y"}`),
		[]ParamSpec{{Name: "x", Required: true, Kind: ParamKindString, Pattern: `(unclosed`}},
	)
	if err == nil {
		t.Fatalf("expected error for bad regex")
	}
	var rpcErr *Error
	if !errors.As(err, &rpcErr) {
		t.Fatalf("expected *Error, got %T", err)
	}
	if rpcErr.Code != codeInternalError {
		t.Fatalf("expected internal error code, got %d", rpcErr.Code)
	}
}
