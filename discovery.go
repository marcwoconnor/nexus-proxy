package main

import (
	"fmt"
	"log"
	"net"
	"sort"
	"sync"
	"time"
)

// DiscoveredServer represents a server found via DNS SRV
type DiscoveredServer struct {
	Address  string
	Port     int
	Priority uint16
	Weight   uint16
}

// Discovery resolves DNS SRV records to find Nexus cluster servers.
// After initial resolution, topology push from the server takes over
// for real-time failover. DNS is re-resolved periodically to pick up
// new nodes or domain changes.
type Discovery struct {
	domain   string // e.g. "dmrnexus.net"
	service  string // e.g. "_nexus._udp"
	servers  []DiscoveredServer
	mu       sync.RWMutex
	interval time.Duration
	stopCh   chan struct{}
}

// NewDiscovery creates a DNS SRV discovery client.
// domain: the base domain (e.g. "dmrnexus.net")
// interval: how often to re-resolve (e.g. 30*time.Minute)
func NewDiscovery(domain string, interval time.Duration) *Discovery {
	return &Discovery{
		domain:   domain,
		service:  "_nexus",
		interval: interval,
		stopCh:   make(chan struct{}),
	}
}

// Resolve performs DNS SRV lookup and returns discovered servers sorted by priority then weight.
// SRV record: _nexus._udp.dmrnexus.net → target:port with priority/weight
func (d *Discovery) Resolve() ([]DiscoveredServer, error) {
	_, addrs, err := net.LookupSRV(d.service, "udp", d.domain)
	if err != nil {
		return nil, fmt.Errorf("SRV lookup %s._udp.%s: %w", d.service, d.domain, err)
	}

	if len(addrs) == 0 {
		return nil, fmt.Errorf("no SRV records for %s._udp.%s", d.service, d.domain)
	}

	servers := make([]DiscoveredServer, 0, len(addrs))
	for _, addr := range addrs {
		// Resolve the SRV target hostname to an IP
		target := addr.Target
		// Strip trailing dot from DNS name
		if len(target) > 0 && target[len(target)-1] == '.' {
			target = target[:len(target)-1]
		}

		servers = append(servers, DiscoveredServer{
			Address:  target,
			Port:     int(addr.Port),
			Priority: addr.Priority,
			Weight:   addr.Weight,
		})
	}

	// Sort by priority (lower = better), then by weight (higher = more likely)
	sort.Slice(servers, func(i, j int) bool {
		if servers[i].Priority != servers[j].Priority {
			return servers[i].Priority < servers[j].Priority
		}
		return servers[i].Weight > servers[j].Weight
	})

	d.mu.Lock()
	d.servers = servers
	d.mu.Unlock()

	return servers, nil
}

// GetServers returns the last-resolved server list
func (d *Discovery) GetServers() []DiscoveredServer {
	d.mu.RLock()
	defer d.mu.RUnlock()
	result := make([]DiscoveredServer, len(d.servers))
	copy(result, d.servers)
	return result
}

// ToServerConfigs converts discovered servers to config format for ClusterClient
func (d *Discovery) ToServerConfigs() []ServerConfig {
	d.mu.RLock()
	defer d.mu.RUnlock()
	configs := make([]ServerConfig, len(d.servers))
	for i, s := range d.servers {
		configs[i] = ServerConfig{Address: s.Address, Port: s.Port}
	}
	return configs
}

// RunBackground periodically re-resolves DNS and logs changes.
// Call this in a goroutine. It blocks until Stop() is called.
func (d *Discovery) RunBackground(onChange func([]DiscoveredServer)) {
	ticker := time.NewTicker(d.interval)
	defer ticker.Stop()

	for {
		select {
		case <-d.stopCh:
			return
		case <-ticker.C:
			servers, err := d.Resolve()
			if err != nil {
				log.Printf("[DNS] re-resolve failed: %v", err)
				continue
			}

			d.mu.RLock()
			changed := len(servers) != len(d.servers)
			if !changed {
				for i := range servers {
					if servers[i].Address != d.servers[i].Address || servers[i].Port != d.servers[i].Port {
						changed = true
						break
					}
				}
			}
			d.mu.RUnlock()

			if changed {
				log.Printf("[DNS] server list updated: %d servers", len(servers))
				if onChange != nil {
					onChange(servers)
				}
			}
		}
	}
}

// Stop terminates the background re-resolve loop
func (d *Discovery) Stop() {
	close(d.stopCh)
}
