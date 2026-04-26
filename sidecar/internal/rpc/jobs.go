package rpc

import (
	"context"
	"sync"
)

// jobEntry holds the cancel func plus a generation counter so a release
// from the first registration of a given id does not delete a later
// registration's entry if a client reuses ids.
type jobEntry struct {
	cancel context.CancelFunc
	gen    uint64
}

// jobRegistry tracks cancellable in-flight handler contexts keyed by
// their JSON-RPC request id. The `jobs.cancel` handler uses it to cancel
// one specific in-flight operation without affecting others.
//
// Lifecycle: Serve registers a new entry just before invoking a handler
// and the deferred release function removes it on return (success or
// error). If a cancel call races the handler finishing, the cancel is
// a no-op because the entry is already gone - that is intentional.
type jobRegistry struct {
	mu   sync.Mutex
	next uint64
	jobs map[string]jobEntry
}

func newJobRegistry() *jobRegistry {
	return &jobRegistry{jobs: make(map[string]jobEntry)}
}

// register stores cancel under id. Returns a release function the
// caller must defer; release also calls cancel to free context
// resources (calling CancelFunc on a context that has already finished
// is a no-op).
func (r *jobRegistry) register(id string, cancel context.CancelFunc) func() {
	r.mu.Lock()
	r.next++
	gen := r.next
	// If two requests share an id (clients should not do this but we
	// won't ruin their day over it), the newer one wins - cancel the
	// older one first so its CancelFunc isn't leaked.
	if prev, ok := r.jobs[id]; ok {
		prev.cancel()
	}
	r.jobs[id] = jobEntry{cancel: cancel, gen: gen}
	r.mu.Unlock()

	return func() {
		r.mu.Lock()
		// Only drop the entry if it's the same generation we installed.
		if cur, ok := r.jobs[id]; ok && cur.gen == gen {
			delete(r.jobs, id)
		}
		r.mu.Unlock()
		cancel()
	}
}

// cancel finds id in the table and calls its CancelFunc. Returns true
// if an entry was found. The release deferred by the handler goroutine
// will clean up the map entry shortly after.
func (r *jobRegistry) cancel(id string) bool {
	r.mu.Lock()
	entry, ok := r.jobs[id]
	r.mu.Unlock()
	if !ok {
		return false
	}
	entry.cancel()
	return true
}

// active returns the number of registered jobs. Intended for tests and
// diagnostics - not part of the JSON-RPC surface.
func (r *jobRegistry) active() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.jobs)
}
