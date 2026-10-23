module github.com/shoenig/go-m1cpu

// iOS stub: the real module uses IOKit sysctl calls that are unavailable
// on iOS (kIOMasterPortDefault). gost only pulls this in via gopsutil's
// CPU metrics, which the embedded tunnel engine does not need.

func IsAppleSilicon() bool { return false }

func PCoreHz() uint64    { return 0 }
func ECoreHz() uint64    { return 0 }
func PCoreGHz() float64  { return 0 }
func ECoreGHz() float64  { return 0 }
func PCoreCount() int    { return 0 }
func ECoreCount() int    { return 0 }

func PCoreCache() (int, int) { return 0, 0 }
func ECoreCache() (int, int) { return 0, 0 }

func ModelName() string { return "" }
