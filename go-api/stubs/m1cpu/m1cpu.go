// Package m1cpu is an iOS-safe stub of github.com/shoenig/go-m1cpu.
// The real module requires IOKit symbols (kIOMasterPortDefault) that do
// not exist in the iOS SDK; gost only reaches it via gopsutil CPU metrics.
package m1cpu

func IsAppleSilicon() bool { return false }

func PCoreHz() uint64   { return 0 }
func ECoreHz() uint64   { return 0 }
func PCoreGHz() float64 { return 0 }
func ECoreGHz() float64 { return 0 }

func PCoreCount() int { return 0 }
func ECoreCount() int { return 0 }

func PCoreCache() (int, int) { return 0, 0 }
func ECoreCache() (int, int) { return 0, 0 }

func ModelName() string { return "" }
