package main

import (
	"syscall"
	"testing"
	"time"
)

func TestWindowsSystemStatistics(t *testing.T) {
	if got := ticks(syscall.Filetime{HighDateTime: 1, LowDateTime: 2}); got != 1<<32|2 {
		t.Fatalf("FILETIME conversion: %d", got)
	}
	s := newCPUSampler()
	if !s.ok {
		t.Fatal("GetSystemTimes unavailable")
	}
	before := procCPU()
	time.Sleep(20 * time.Millisecond)
	if pct := s.sample(); pct == nil || *pct < 0 || *pct > 100 {
		t.Fatalf("invalid system CPU measurement: %v", pct)
	}
	if procCPU() < before {
		t.Fatal("process CPU time decreased")
	}
	if rssMB() <= 0 || peakRSSMB() <= 0 {
		t.Fatal("process memory measurements missing")
	}
	if !isConnGone(syscall.Errno(10053)) || !isConnGone(syscall.Errno(10054)) {
		t.Fatal("Windows aborted connection is not retryable")
	}
}
