// Parameter validation helpers for JSON-RPC handlers.
//
// Many handlers start with a hand-rolled `json.Unmarshal(raw, &req)` that
// accepts any JSON at all and then hopes the domain layer catches the
// nonsense later. ParamSpec lets a handler declare its required fields
// and simple type constraints up-front so bad input is rejected at the
// RPC boundary with a consistent codeInvalidParams (-32602) error.
//
// This is intentionally thin - we are not building json-schema here. It
// covers the 90% case (required? type? length? pattern?) and leaves
// domain-specific validation (is this a git ref? is this path under the
// data dir?) to the handler itself where it belongs.

package rpc

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"sync"
)

// ParamKind enumerates the JSON types ParamSpec can validate.
type ParamKind string

// Supported parameter kinds. Mirror the JSON type names for consistency.
const (
	ParamKindString ParamKind = "string"
	ParamKindInt    ParamKind = "int"
	ParamKindBool   ParamKind = "bool"
	ParamKindObject ParamKind = "object"
	ParamKindArray  ParamKind = "array"
)

// ParamSpec describes a single JSON-RPC parameter.
//
// Only fields relevant to the Kind are consulted: MinLen/MaxLen/Pattern
// only apply to string/array kinds; other combinations are silently
// ignored rather than rejected so a shared spec can be reused verbatim
// across similar handlers.
type ParamSpec struct {
	Name     string
	Required bool
	Kind     ParamKind
	MinLen   int    // for string/array; 0 means unset
	MaxLen   int    // for string/array; 0 means unset
	Pattern  string // regex for string kind; empty means unset
}

// compiledPatternCache avoids recompiling the same regex per call.
// ParamSpec is usually a static slice built once at handler registration
// but ValidateParams is called on every request so the hot path matters.
var (
	patternCacheMu sync.RWMutex
	patternCache   = map[string]*regexp.Regexp{}
)

func compilePattern(p string) (*regexp.Regexp, error) {
	patternCacheMu.RLock()
	if re, ok := patternCache[p]; ok {
		patternCacheMu.RUnlock()
		return re, nil
	}
	patternCacheMu.RUnlock()

	re, err := regexp.Compile(p)
	if err != nil {
		return nil, err
	}
	patternCacheMu.Lock()
	patternCache[p] = re
	patternCacheMu.Unlock()
	return re, nil
}

// ValidateParams checks raw against specs and returns an *Error with
// code codeInvalidParams (-32602) on the first violation.
//
// An empty or null raw is treated as "no params" - specs with Required
// true then fail with "missing required param".
func ValidateParams(raw json.RawMessage, specs []ParamSpec) error {
	var fields map[string]json.RawMessage
	if len(raw) > 0 && string(raw) != "null" {
		if err := json.Unmarshal(raw, &fields); err != nil {
			return &Error{
				Code:    codeInvalidParams,
				Message: fmt.Sprintf("params must be a JSON object: %v", err),
			}
		}
	}

	for _, spec := range specs {
		val, present := fields[spec.Name]
		if !present || len(val) == 0 || string(val) == "null" {
			if spec.Required {
				return &Error{
					Code:    codeInvalidParams,
					Message: fmt.Sprintf("missing required param %q", spec.Name),
				}
			}
			continue
		}
		if err := validateField(spec, val); err != nil {
			return err
		}
	}
	return nil
}

func validateField(spec ParamSpec, val json.RawMessage) error {
	switch spec.Kind {
	case ParamKindString:
		var s string
		if err := json.Unmarshal(val, &s); err != nil {
			return invalidKind(spec, "string")
		}
		if spec.MinLen > 0 && len(s) < spec.MinLen {
			return &Error{
				Code:    codeInvalidParams,
				Message: fmt.Sprintf("param %q is shorter than min length %d", spec.Name, spec.MinLen),
			}
		}
		if spec.MaxLen > 0 && len(s) > spec.MaxLen {
			return &Error{
				Code:    codeInvalidParams,
				Message: fmt.Sprintf("param %q exceeds max length %d", spec.Name, spec.MaxLen),
			}
		}
		if spec.Pattern != "" {
			re, err := compilePattern(spec.Pattern)
			if err != nil {
				// A broken regex is a programmer error, not a caller
				// error - surface it as internal rather than invalid
				// params so the bug lands in the server log.
				return &Error{
					Code:    codeInternalError,
					Message: fmt.Sprintf("param %q: bad validation regex: %v", spec.Name, err),
				}
			}
			if !re.MatchString(s) {
				return &Error{
					Code:    codeInvalidParams,
					Message: fmt.Sprintf("param %q does not match pattern %q", spec.Name, spec.Pattern),
				}
			}
		}
	case ParamKindInt:
		// We accept whole JSON numbers only - no JSON-string-wrapped
		// digits, no floats. The first byte of a raw JSON number is
		// always a digit or minus sign; a quoted string starts with `"`.
		if !isJSONNumber(val) {
			return invalidKind(spec, "int")
		}
		var n json.Number
		dec := json.NewDecoder(bytesReader(val))
		dec.UseNumber()
		if err := dec.Decode(&n); err != nil {
			return invalidKind(spec, "int")
		}
		if _, err := n.Int64(); err != nil {
			return invalidKind(spec, "int")
		}
	case ParamKindBool:
		var b bool
		if err := json.Unmarshal(val, &b); err != nil {
			return invalidKind(spec, "bool")
		}
	case ParamKindObject:
		// A raw JSON object has to start with `{` after whitespace.
		if !startsWith(val, '{') {
			return invalidKind(spec, "object")
		}
	case ParamKindArray:
		if !startsWith(val, '[') {
			return invalidKind(spec, "array")
		}
		if spec.MinLen > 0 || spec.MaxLen > 0 {
			var arr []json.RawMessage
			if err := json.Unmarshal(val, &arr); err != nil {
				return invalidKind(spec, "array")
			}
			if spec.MinLen > 0 && len(arr) < spec.MinLen {
				return &Error{
					Code:    codeInvalidParams,
					Message: fmt.Sprintf("param %q has fewer than %d items", spec.Name, spec.MinLen),
				}
			}
			if spec.MaxLen > 0 && len(arr) > spec.MaxLen {
				return &Error{
					Code:    codeInvalidParams,
					Message: fmt.Sprintf("param %q has more than %d items", spec.Name, spec.MaxLen),
				}
			}
		}
	}
	return nil
}

func invalidKind(spec ParamSpec, want string) *Error {
	return &Error{
		Code:    codeInvalidParams,
		Message: fmt.Sprintf("param %q must be a %s", spec.Name, want),
	}
}

func startsWith(raw json.RawMessage, b byte) bool {
	for _, c := range raw {
		switch c {
		case ' ', '\t', '\n', '\r':
			continue
		default:
			return c == b
		}
	}
	return false
}

// isJSONNumber reports whether the first non-whitespace byte of raw is
// the start of a JSON number (digit or minus sign). A quoted string or
// literal will not match.
func isJSONNumber(raw json.RawMessage) bool {
	for _, c := range raw {
		switch c {
		case ' ', '\t', '\n', '\r':
			continue
		case '-':
			return true
		default:
			return c >= '0' && c <= '9'
		}
	}
	return false
}

func bytesReader(raw json.RawMessage) io.Reader {
	return bytes.NewReader(raw)
}
