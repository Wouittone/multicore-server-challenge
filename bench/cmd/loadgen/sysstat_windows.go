package main

import (
	"fmt"
	"syscall"
	"time"
	"unsafe"
)

var (
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	getSystemTimes       = kernel32.NewProc("GetSystemTimes")
	getProcessTimes      = kernel32.NewProc("GetProcessTimes")
	getCurrentProcess    = kernel32.NewProc("GetCurrentProcess")
	getProcessMemoryInfo = syscall.NewLazyDLL("psapi.dll").NewProc("GetProcessMemoryInfo")
)

type cpuSampler struct {
	busy, total uint64
	ok          bool
}

func ticks(t syscall.Filetime) uint64 {
	return uint64(t.HighDateTime)<<32 | uint64(t.LowDateTime)
}

func readProcStat() (busy, total uint64, ok bool) {
	var idle, kernel, user syscall.Filetime
	result, _, _ := getSystemTimes.Call(uintptr(unsafe.Pointer(&idle)),
		uintptr(unsafe.Pointer(&kernel)), uintptr(unsafe.Pointer(&user)))
	if result == 0 {
		return 0, 0, false
	}
	total = ticks(kernel) + ticks(user)
	return total - ticks(idle), total, true
}

func newCPUSampler() *cpuSampler {
	s := &cpuSampler{}
	s.busy, s.total, s.ok = readProcStat()
	return s
}

func (s *cpuSampler) sample() *float64 {
	if !s.ok {
		return nil
	}
	b, t, ok := readProcStat()
	if !ok || t <= s.total {
		return nil
	}
	pct := 100 * float64(b-s.busy) / float64(t-s.total)
	s.busy, s.total = b, t
	return &pct
}

func procCPU() time.Duration {
	process, _, _ := getCurrentProcess.Call()
	var created, exited, kernel, user syscall.Filetime
	result, _, err := getProcessTimes.Call(process, uintptr(unsafe.Pointer(&created)),
		uintptr(unsafe.Pointer(&exited)), uintptr(unsafe.Pointer(&kernel)),
		uintptr(unsafe.Pointer(&user)))
	if result == 0 {
		panic(fmt.Sprintf("GetProcessTimes: %v", err))
	}
	return time.Duration(ticks(kernel)+ticks(user)) * 100 * time.Nanosecond
}

type processMemoryCounters struct {
	size, pageFaultCount                               uint32
	peakWorkingSetSize, workingSetSize                 uintptr
	quotaPeakPagedPoolUsage, quotaPagedPoolUsage       uintptr
	quotaPeakNonPagedPoolUsage, quotaNonPagedPoolUsage uintptr
	pagefileUsage, peakPagefileUsage                   uintptr
}

func memoryCounters() processMemoryCounters {
	process, _, _ := getCurrentProcess.Call()
	var counters processMemoryCounters
	counters.size = uint32(unsafe.Sizeof(counters))
	result, _, err := getProcessMemoryInfo.Call(process,
		uintptr(unsafe.Pointer(&counters)), uintptr(counters.size))
	if result == 0 {
		panic(fmt.Sprintf("GetProcessMemoryInfo: %v", err))
	}
	return counters
}

func rssMB() float64 {
	return float64(memoryCounters().workingSetSize) / (1 << 20)
}

func peakRSSMB() float64 {
	return float64(memoryCounters().peakWorkingSetSize) / (1 << 20)
}
