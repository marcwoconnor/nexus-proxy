package main

import (
	"fmt"
	"log"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	cfgPath := "config.json"
	if len(os.Args) > 1 {
		cfgPath = os.Args[1]
	}

	cfg, err := LoadConfig(cfgPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "config error: %v\n", err)
		os.Exit(1)
	}

	// Configure logging
	log.SetFlags(log.Ldate | log.Ltime | log.Lmicroseconds)

	// DNS SRV discovery: resolve servers before starting proxy
	var disc *Discovery
	if cfg.Cluster.Discovery != "" {
		interval := time.Duration(cfg.Cluster.DiscoveryInterval) * time.Minute
		disc = NewDiscovery(cfg.Cluster.Discovery, interval)

		log.Printf("resolving servers via DNS SRV: _nexus._udp.%s", cfg.Cluster.Discovery)
		servers, err := disc.Resolve()
		if err != nil {
			log.Fatalf("DNS discovery failed: %v", err)
		}
		log.Printf("discovered %d server(s):", len(servers))
		for _, s := range servers {
			log.Printf("  %s:%d (priority=%d weight=%d)", s.Address, s.Port, s.Priority, s.Weight)
		}

		// Populate config with discovered servers
		cfg.Cluster.Servers = disc.ToServerConfigs()
	}

	log.Printf("cluster-proxy starting — repeater_id=%d servers=%d",
		cfg.Local.RepeaterID, len(cfg.Cluster.Servers))

	proxy, err := NewProxy(cfg)
	if err != nil {
		log.Fatalf("failed to create proxy: %v", err)
	}

	// Start background DNS re-resolution
	if disc != nil {
		go disc.RunBackground(func(servers []DiscoveredServer) {
			log.Printf("[DNS] server list changed — %d servers (topology push handles live failover)", len(servers))
			// Note: we don't hot-swap connections on DNS change.
			// Topology push from the server handles real-time failover.
			// DNS re-resolve catches node additions/removals between restarts.
		})
	}

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		log.Printf("received %v — shutting down", sig)
		if disc != nil {
			disc.Stop()
		}
		proxy.Close()
		os.Exit(0)
	}()

	proxy.Run()
}
