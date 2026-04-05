package main

import (
	"encoding/json"
	"fmt"
	"os"
)

type Config struct {
	// Local HomeBrew listener (accepts MMDVMHost / DMRGateway)
	Local LocalConfig `json:"local"`

	// Upstream cluster-native connection(s)
	Cluster ClusterConfig `json:"cluster"`

	// Talkgroup subscriptions (default; RPTO from client overrides)
	Subscription SubscriptionConfig `json:"subscription"`

	// Logging
	LogLevel string `json:"log_level"` // debug, info, warn, error
}

type LocalConfig struct {
	Address    string `json:"address"`     // bind address (default 0.0.0.0)
	Port       int    `json:"port"`        // listen port (default 62031)
	Passphrase string `json:"passphrase"`  // auth passphrase for local repeaters
	RepeaterID uint32 `json:"repeater_id"` // our repeater ID for upstream auth
}

type ClusterConfig struct {
	// Manual server list (traditional mode)
	Servers []ServerConfig `json:"servers,omitempty"`

	// DNS SRV discovery (Pi-Star mode) — mutually exclusive with Servers
	// Set to a domain like "dmrnexus.net" and servers are discovered via
	// _nexus._udp.dmrnexus.net SRV records. Once connected, topology push
	// from the server provides real-time failover.
	Discovery string `json:"discovery,omitempty"`

	// DNS re-resolve interval in minutes (default 30)
	DiscoveryInterval int `json:"discovery_interval,omitempty"`

	Passphrase   string `json:"passphrase"`    // passphrase for upstream cluster auth
	PingInterval int    `json:"ping_interval"` // seconds (default 5)
	PingTimeout  int    `json:"ping_timeout"`  // missed pings before failover (default 3)
}

type ServerConfig struct {
	Address string `json:"address"`
	Port    int    `json:"port"`
}

type SubscriptionConfig struct {
	Slot1 []uint32 `json:"slot1"` // talkgroup IDs for timeslot 1
	Slot2 []uint32 `json:"slot2"` // talkgroup IDs for timeslot 2
}

func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config: %w", err)
	}
	cfg := &Config{
		Local: LocalConfig{
			Address: "0.0.0.0",
			Port:    62031,
		},
		Cluster: ClusterConfig{
			PingInterval:      5,
			PingTimeout:       3,
			DiscoveryInterval: 30,
		},
		LogLevel: "info",
	}
	if err := json.Unmarshal(data, cfg); err != nil {
		return nil, fmt.Errorf("parse config: %w", err)
	}
	if err := cfg.validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

func (c *Config) validate() error {
	if c.Local.RepeaterID == 0 {
		return fmt.Errorf("local.repeater_id required")
	}
	if c.Cluster.Discovery == "" && len(c.Cluster.Servers) == 0 {
		return fmt.Errorf("either cluster.discovery or cluster.servers required")
	}
	if c.Cluster.Discovery != "" && len(c.Cluster.Servers) > 0 {
		return fmt.Errorf("cluster.discovery and cluster.servers are mutually exclusive")
	}
	if c.Cluster.Passphrase == "" {
		return fmt.Errorf("cluster.passphrase required")
	}
	for i, s := range c.Cluster.Servers {
		if s.Address == "" {
			return fmt.Errorf("cluster.servers[%d].address required", i)
		}
		if s.Port == 0 {
			return fmt.Errorf("cluster.servers[%d].port required", i)
		}
	}
	return nil
}
