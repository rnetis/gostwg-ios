// gost_api.go exposes the gost sidecar to Swift through the same c-archive
// mechanism WireGuardKitGo uses for the wg* functions.
package main

// #include <stdlib.h>
// #include <string.h>
// static void gostCallLogger(void *func, void *ctx, int level, const char *msg)
// {
//      ((void(*)(void *, int, const char *))func)(ctx, level, msg);
// }
import "C"

import (
	"encoding/json"
	"unsafe"

	"golang.zx2c4.com/wireguard/apple/gostsidecar"
)

// gostForwardLog routes gostsidecar log lines into the WireGuard C logger
// registered by wgSetLogger, so gost and wireguard-go logs appear in the
// same Swift log handler.
func gostForwardLog(level int, msg string) {
	if uintptr(loggerFunc) == 0 {
		return
	}
	cs := cstring(msg)
	C.gostCallLogger(loggerFunc, loggerCtx, C.int(level), cs)
}

//export gostStart
// gostStart starts the embedded gost sidecar. configJSON is a gostsidecar.Config:
//
//	{"services":["udp://:51820/127.0.0.1:51820"],
//	 "nodes":["relay+icmp://vpn.example.com:12345"],
//	 "debug":false}
//
// Returns 0 on success, -1 on failure (the failure is also logged through
// the WireGuard logger).
func gostStart(configJSON *C.char) C.int {
	if configJSON == nil {
		return -1
	}
	gostsidecar.SetLogSink(gostForwardLog)

	var cfg gostsidecar.Config
	if err := json.Unmarshal([]byte(C.GoString(configJSON)), &cfg); err != nil {
		gostForwardLog(1, "gost: invalid config: "+err.Error())
		return -1
	}
	if err := gostsidecar.Start(cfg); err != nil {
		gostForwardLog(1, err.Error())
		return -1
	}
	gostForwardLog(0, "gost: sidecar started")
	return 0
}

//export gostStop
func gostStop() {
	gostsidecar.Stop()
}

//export gostIsRunning
func gostIsRunning() C.int {
	if gostsidecar.IsRunning() {
		return 1
	}
	return 0
}

var _ = unsafe.Pointer(nil)
