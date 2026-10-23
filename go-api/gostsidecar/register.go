// Slim component registration for the embedded gost sidecar.
//
// The gost CLI blank-imports every implementation in go-gost/x (see
// go-gost/gost cmd/gost/register.go). The sidecar only needs the components
// involved in the WireGuard-over-relay+icmp forwarding path (plus a few
// defaults the config parser instantiates unconditionally), which keeps the
// iOS Network Extension binary small.
package gostsidecar

import (
	// Connectors
	_ "github.com/go-gost/x/connector/direct"
	_ "github.com/go-gost/x/connector/forward"
	_ "github.com/go-gost/x/connector/http"
	_ "github.com/go-gost/x/connector/relay"
	_ "github.com/go-gost/x/connector/tcp"

	// Dialers
	_ "github.com/go-gost/x/dialer/direct"
	_ "github.com/go-gost/x/dialer/icmp"
	_ "github.com/go-gost/x/dialer/tcp"
	_ "github.com/go-gost/x/dialer/udp"

	// Handlers ("udp" = forward/local, used by -L udp://...)
	_ "github.com/go-gost/x/handler/forward/local"
	_ "github.com/go-gost/x/handler/relay"

	// Listeners
	_ "github.com/go-gost/x/listener/icmp"
	_ "github.com/go-gost/x/listener/udp"
)
