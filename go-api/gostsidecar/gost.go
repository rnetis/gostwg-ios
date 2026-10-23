// Package gostsidecar embeds gost (https://github.com/go-gost) inside the
// iOS Packet Tunnel Provider process. It runs the same service definitions
// that the gost CLI would run from command line flags, so the transport
// behaves identically to running:
//
//      gost -L "udp://:51820/127.0.0.1:51820" -F "relay+icmp://server:12345"
//
// on the device. WireGuard (wireguard-go, started separately by the Swift
// adapter) is configured with Endpoint = 127.0.0.1:<localPort>, so its UDP
// packets loop back inside the process and get relayed to the gost server
// over ICMP echo request/reply (QUIC-over-ICMP), where they are delivered to
// the real WireGuard server listening on 127.0.0.1:51820.
package gostsidecar

import (
        "errors"
        "fmt"
        "strings"
        "sync"

        "github.com/go-gost/core/logger"
        "github.com/go-gost/core/service"
        "github.com/go-gost/x/config/loader"
        "github.com/go-gost/x/config/parsing/parser"
        "github.com/go-gost/x/registry"
)

const (
        // gostLogVerbose and gostLogError map onto the WireGuard C logger levels.
        gostLogVerbose = 0
        gostLogError   = 1
)

// Config is the JSON document passed from Swift through gostStart().
type Config struct {
        // Services is the list of gost -L style service definitions,
        // e.g. "udp://:51820/127.0.0.1:51820".
        Services []string `json:"services"`

        // Nodes is the list of gost -F style chain node definitions,
        // e.g. "relay+icmp://vpn.example.com:12345".
        Nodes []string `json:"nodes"`

        // Debug enables gost debug-level logging.
        Debug bool `json:"debug,omitempty"`
}

// LogFunc receives gost log lines. level is 0 for verbose/debug/info and
// 1 for warn/error/fatal, matching the WireGuard log levels.
type LogFunc func(level int, msg string)

var (
        mu       sync.Mutex
        running  bool
        svcs     []service.Service
        logSink  LogFunc
        logLevel = logger.InfoLevel
)

// SetLogSink routes gost logs to the given function (called from multiple
// goroutines; the sink must be thread safe).
func SetLogSink(fn LogFunc) {
        mu.Lock()
        logSink = fn
        mu.Unlock()
}

// SetVerbose toggles debug-level logging through the sink.
func SetVerbose(v bool) {
        mu.Lock()
        if v {
                logLevel = logger.DebugLevel
        } else {
                logLevel = logger.InfoLevel
        }
        mu.Unlock()
}

// bridgeLogger forwards gost logs to the configured sink.
type bridgeLogger struct {
        fields string
}

func (b *bridgeLogger) format(level logger.LogLevel, msg string) string {
        if b.fields != "" {
                return string(level) + " " + b.fields + " " + msg
        }
        return string(level) + " " + msg
}

func (b *bridgeLogger) emit(level logger.LogLevel, msg string) {
        mu.Lock()
        fn := logSink
        mu.Unlock()
        if fn == nil {
                return
        }
        lvl := gostLogVerbose
        switch level {
        case logger.WarnLevel, logger.ErrorLevel, logger.FatalLevel:
                lvl = gostLogError
        }
        fn(lvl, b.format(level, msg))
}

func (b *bridgeLogger) WithFields(m map[string]any) logger.Logger {
        if len(m) == 0 {
                return b
        }
        parts := make([]string, 0, len(m))
        for k, v := range m {
                parts = append(parts, fmt.Sprintf("%s=%v", k, v))
        }
        return &bridgeLogger{fields: strings.Join(parts, " ")}
}

func (b *bridgeLogger) Trace(args ...any) { b.debugLog(logger.TraceLevel, sprintln(args...)) }
func (b *bridgeLogger) Tracef(f string, args ...any) {
        b.debugLog(logger.TraceLevel, fmt.Sprintf(f, args...))
}
func (b *bridgeLogger) Debug(args ...any) { b.debugLog(logger.DebugLevel, sprintln(args...)) }
func (b *bridgeLogger) Debugf(f string, args ...any) {
        b.debugLog(logger.DebugLevel, fmt.Sprintf(f, args...))
}
func (b *bridgeLogger) Info(args ...any) { b.debugLog(logger.InfoLevel, sprintln(args...)) }
func (b *bridgeLogger) Infof(f string, args ...any) {
        b.debugLog(logger.InfoLevel, fmt.Sprintf(f, args...))
}
func (b *bridgeLogger) Warn(args ...any) { b.debugLog(logger.WarnLevel, sprintln(args...)) }
func (b *bridgeLogger) Warnf(f string, args ...any) {
        b.debugLog(logger.WarnLevel, fmt.Sprintf(f, args...))
}
func (b *bridgeLogger) Error(args ...any) { b.debugLog(logger.ErrorLevel, sprintln(args...)) }
func (b *bridgeLogger) Errorf(f string, args ...any) {
        b.debugLog(logger.ErrorLevel, fmt.Sprintf(f, args...))
}
func (b *bridgeLogger) Fatal(args ...any) { b.debugLog(logger.FatalLevel, sprintln(args...)) }
func (b *bridgeLogger) Fatalf(f string, args ...any) {
        b.debugLog(logger.FatalLevel, fmt.Sprintf(f, args...))
}

func (b *bridgeLogger) debugLog(level logger.LogLevel, msg string) {
        mu.Lock()
        threshold := logLevel
        mu.Unlock()
        if !enabled(level, threshold) {
                return
        }
        b.emit(level, b.format(level, msg))
}

func (b *bridgeLogger) GetLevel() logger.LogLevel {
        mu.Lock()
        defer mu.Unlock()
        return logLevel
}

func (b *bridgeLogger) IsLevelEnabled(level logger.LogLevel) bool {
        mu.Lock()
        threshold := logLevel
        mu.Unlock()
        return enabled(level, threshold)
}

func enabled(level, threshold logger.LogLevel) bool {
        rank := func(l logger.LogLevel) int {
                switch l {
                case logger.TraceLevel:
                        return 0
                case logger.DebugLevel:
                        return 1
                case logger.InfoLevel:
                        return 2
                case logger.WarnLevel:
                        return 3
                case logger.ErrorLevel:
                        return 4
                case logger.FatalLevel:
                        return 5
                }
                return 2
        }
        return rank(level) >= rank(threshold)
}

func sprintln(args ...any) string {
        return strings.TrimSuffix(fmt.Sprintln(args...), "\n")
}

// Start builds and starts the gost services described by cfg.
// It returns once the services are constructed; Serve() runs in background
// goroutines (datagram forwarding is fully asynchronous anyway).
func Start(cfg Config) error {
        mu.Lock()
        if running {
                mu.Unlock()
                return errors.New("gost: already running")
        }
        mu.Unlock()

        if len(cfg.Services) == 0 {
                return errors.New("gost: no services defined")
        }

        // Route gost logs through the sink. loader.Load installs the default
        // logger; the vendored loader patch makes it use our bridge logger so
        // the concrete type stored in logger's atomic.Value stays consistent
        // across restarts.
        bl := &bridgeLogger{}
        loader.DefaultLoggerOverride = bl

        parser.Init(parser.Args{
                Services: cfg.Services,
                Nodes:    cfg.Nodes,
                Debug:    cfg.Debug,
        })
        gcfg, err := parser.Parse()
        if err != nil {
                return fmt.Errorf("gost: parse config: %w", err)
        }

        if err := loader.Load(gcfg); err != nil {
                return fmt.Errorf("gost: load config: %w", err)
        }

        logger.Default().Debug("gost: config loaded")

        mu.Lock()
        defer mu.Unlock()
        for _, svc := range registry.ServiceRegistry().GetAll() {
                svc := svc
                svcs = append(svcs, svc)
                go func() {
                        if err := svc.Serve(); err != nil {
                                mu.Lock()
                                fn := logSink
                                mu.Unlock()
                                msg := "gost: service stopped: " + err.Error()
                                if fn != nil {
                                        fn(1, msg)
                                }
                        }
                }()
        }
        running = true
        return nil
}

// Stop closes all gost services. Safe to call multiple times.
func Stop() {
        mu.Lock()
        defer mu.Unlock()
        for _, svc := range svcs {
                svc.Close()
        }
        svcs = nil
        running = false
}

// IsRunning reports whether the sidecar has been started.
func IsRunning() bool {
        mu.Lock()
        defer mu.Unlock()
        return running
}
