// Package rpc implements JSON-RPC 2.0 framing over line-delimited JSON
// on stdin/stdout. It's the single IPC surface between the Flutter app
// and the Go sidecar.
package rpc

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"sync"
)

// Handler handles a single JSON-RPC method call. Return value is
// JSON-marshaled back to the UI as `result`.
type Handler func(ctx context.Context, params json.RawMessage) (any, error)

// Server is a JSON-RPC 2.0 server that reads requests one-per-line from
// stdin and writes responses one-per-line to stdout.
type Server struct {
	mu       sync.RWMutex
	handlers map[string]Handler
}

// NewServer returns a Server with no handlers registered.
func NewServer() *Server {
	return &Server{handlers: make(map[string]Handler)}
}

// Register adds a handler for [method]. Replaces any existing handler.
func (s *Server) Register(method string, h Handler) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handlers[method] = h
}

// Serve runs the read/dispatch/respond loop until [ctx] is cancelled or
// the input stream closes.
func (s *Server) Serve(ctx context.Context, in io.Reader, out io.Writer) error {
	scanner := bufio.NewScanner(in)
	scanner.Buffer(make([]byte, 1<<16), 1<<24) // up to 16 MB per message

	writer := bufio.NewWriter(out)
	writerMu := &sync.Mutex{}

	writeResponse := func(msg any) {
		writerMu.Lock()
		defer writerMu.Unlock()
		enc := json.NewEncoder(writer)
		if err := enc.Encode(msg); err != nil {
			// best-effort; don't crash the server on encode failures
			return
		}
		_ = writer.Flush()
	}

	for scanner.Scan() {
		if ctx.Err() != nil {
			return ctx.Err()
		}

		line := append([]byte(nil), scanner.Bytes()...) // copy — buffer reused

		var req request
		if err := json.Unmarshal(line, &req); err != nil {
			writeResponse(errorResponse(nil, codeParseError, "parse error", nil))
			continue
		}

		if req.JSONRPC != "2.0" {
			writeResponse(errorResponse(req.ID, codeInvalidRequest, "missing or bad jsonrpc version", nil))
			continue
		}

		s.mu.RLock()
		h, ok := s.handlers[req.Method]
		s.mu.RUnlock()
		if !ok {
			writeResponse(errorResponse(req.ID, codeMethodNotFound, fmt.Sprintf("unknown method %q", req.Method), nil))
			continue
		}

		// Dispatch synchronously for now; parallel dispatch lands when
		// long-running handlers need it.
		result, err := h(ctx, req.Params)
		if err != nil {
			writeResponse(errorResponse(req.ID, codeInternalError, err.Error(), nil))
			continue
		}
		writeResponse(successResponse(req.ID, result))
	}
	return scanner.Err()
}

// -------------------------------------------------------------------
// message types + error codes

type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *responseError  `json:"error,omitempty"`
}

type responseError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

const (
	codeParseError     = -32700
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeInternalError  = -32603
)

func successResponse(id json.RawMessage, result any) response {
	return response{JSONRPC: "2.0", ID: id, Result: result}
}

func errorResponse(id json.RawMessage, code int, msg string, data any) response {
	return response{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &responseError{Code: code, Message: msg, Data: data},
	}
}
