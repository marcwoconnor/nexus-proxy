package main

import (
	"os"
	"testing"
	"time"
)

func TestNewDiscovery(t *testing.T) {
	d := NewDiscovery("example.com", 30*time.Minute)
	if d.domain != "example.com" {
		t.Errorf("domain = %s", d.domain)
	}
	if d.service != "_nexus" {
		t.Errorf("service = %s", d.service)
	}
	if d.interval != 30*time.Minute {
		t.Errorf("interval = %v", d.interval)
	}
}

func TestGetServersEmpty(t *testing.T) {
	d := NewDiscovery("example.com", time.Minute)
	servers := d.GetServers()
	if len(servers) != 0 {
		t.Errorf("expected empty, got %d", len(servers))
	}
}

func TestToServerConfigs(t *testing.T) {
	d := NewDiscovery("example.com", time.Minute)
	d.servers = []DiscoveredServer{
		{Address: "south.example.com", Port: 62031, Priority: 10, Weight: 50},
		{Address: "north.example.com", Port: 62031, Priority: 20, Weight: 30},
	}

	configs := d.ToServerConfigs()
	if len(configs) != 2 {
		t.Fatalf("len = %d", len(configs))
	}
	if configs[0].Address != "south.example.com" {
		t.Errorf("configs[0].Address = %s", configs[0].Address)
	}
	if configs[0].Port != 62031 {
		t.Errorf("configs[0].Port = %d", configs[0].Port)
	}
	if configs[1].Address != "north.example.com" {
		t.Errorf("configs[1].Address = %s", configs[1].Address)
	}
}

func TestDiscoveredServerSorting(t *testing.T) {
	d := NewDiscovery("example.com", time.Minute)
	// Simulate pre-sorted result
	d.servers = []DiscoveredServer{
		{Address: "backup.example.com", Port: 62031, Priority: 20, Weight: 10},
		{Address: "primary.example.com", Port: 62031, Priority: 10, Weight: 50},
		{Address: "primary2.example.com", Port: 62031, Priority: 10, Weight: 30},
	}

	// ToServerConfigs preserves order
	configs := d.ToServerConfigs()
	if configs[0].Address != "backup.example.com" {
		t.Errorf("expected backup first (pre-sorted), got %s", configs[0].Address)
	}
}

func TestParseTopology(t *testing.T) {
	json := `{"v":1,"seq":42,"servers":[` +
		`{"node_id":"nexus-1","address":"10.31.11.40","port":62031,"alive":true,"draining":false,"load":3,"latency_ms":2.5,"priority":3},` +
		`{"node_id":"nexus-2","address":"10.31.11.41","port":62031,"alive":true,"draining":true,"load":1,"latency_ms":1.0,"priority":9000},` +
		`{"node_id":"nexus-3","address":"10.31.11.52","port":62031,"alive":false,"draining":false,"load":0,"latency_ms":0,"priority":9999}` +
		`]}`

	pkt := make([]byte, 8+len(json))
	copy(pkt[0:4], NativeMagic)
	copy(pkt[4:8], CmdTopo)
	copy(pkt[8:], json)

	topo, err := ParseTopology(pkt)
	if err != nil {
		t.Fatalf("ParseTopology: %v", err)
	}
	if topo.Version != 1 {
		t.Errorf("version = %d", topo.Version)
	}
	if topo.Seq != 42 {
		t.Errorf("seq = %d", topo.Seq)
	}
	if len(topo.Servers) != 3 {
		t.Fatalf("servers = %d", len(topo.Servers))
	}

	// Server 1: alive, not draining
	s1 := topo.Servers[0]
	if s1.NodeID != "nexus-1" || !s1.Alive || s1.Draining || s1.Load != 3 {
		t.Errorf("server 1 = %+v", s1)
	}

	// Server 2: alive but draining
	s2 := topo.Servers[1]
	if s2.NodeID != "nexus-2" || !s2.Alive || !s2.Draining {
		t.Errorf("server 2 = %+v", s2)
	}

	// Server 3: dead
	s3 := topo.Servers[2]
	if s3.NodeID != "nexus-3" || s3.Alive || s3.Priority != 9999 {
		t.Errorf("server 3 = %+v", s3)
	}
}

func TestParseTopologyTooShort(t *testing.T) {
	pkt := make([]byte, 8)
	copy(pkt[0:4], NativeMagic)
	copy(pkt[4:8], CmdTopo)
	_, err := ParseTopology(pkt)
	if err == nil {
		t.Error("expected error for empty topo")
	}
}

func TestParseTopologyBadJSON(t *testing.T) {
	pkt := append([]byte("NXCPTOPO"), []byte("not json")...)
	_, err := ParseTopology(pkt)
	if err == nil {
		t.Error("expected error for bad JSON")
	}
}

func TestConfigDiscoveryMode(t *testing.T) {
	json := `{
		"local": {"address": "127.0.0.1", "port": 62031, "passphrase": "test", "repeater_id": 312100},
		"cluster": {"discovery": "dmrnexus.net", "passphrase": "secret"},
		"log_level": "info"
	}`

	// Write temp config
	tmpFile := "/tmp/nexus-proxy-test-config.json"
	if err := writeTestFile(tmpFile, json); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(tmpFile)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Cluster.Discovery != "dmrnexus.net" {
		t.Errorf("discovery = %s", cfg.Cluster.Discovery)
	}
	if len(cfg.Cluster.Servers) != 0 {
		t.Errorf("servers should be empty in discovery mode, got %d", len(cfg.Cluster.Servers))
	}
}

func TestConfigManualMode(t *testing.T) {
	json := `{
		"local": {"address": "127.0.0.1", "port": 62031, "passphrase": "test", "repeater_id": 312100},
		"cluster": {"servers": [{"address": "10.0.0.1", "port": 62031}], "passphrase": "secret"},
		"log_level": "info"
	}`

	tmpFile := "/tmp/nexus-proxy-test-config2.json"
	if err := writeTestFile(tmpFile, json); err != nil {
		t.Fatal(err)
	}

	cfg, err := LoadConfig(tmpFile)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	if cfg.Cluster.Discovery != "" {
		t.Errorf("discovery should be empty in manual mode")
	}
	if len(cfg.Cluster.Servers) != 1 {
		t.Errorf("servers = %d", len(cfg.Cluster.Servers))
	}
}

func TestConfigMutualExclusion(t *testing.T) {
	json := `{
		"local": {"address": "127.0.0.1", "port": 62031, "passphrase": "test", "repeater_id": 312100},
		"cluster": {"discovery": "dmrnexus.net", "servers": [{"address": "10.0.0.1", "port": 62031}], "passphrase": "secret"}
	}`

	tmpFile := "/tmp/nexus-proxy-test-config3.json"
	if err := writeTestFile(tmpFile, json); err != nil {
		t.Fatal(err)
	}

	_, err := LoadConfig(tmpFile)
	if err == nil {
		t.Error("expected error when both discovery and servers are set")
	}
}

func TestConfigNeitherMode(t *testing.T) {
	json := `{
		"local": {"address": "127.0.0.1", "port": 62031, "passphrase": "test", "repeater_id": 312100},
		"cluster": {"passphrase": "secret"}
	}`

	tmpFile := "/tmp/nexus-proxy-test-config4.json"
	if err := writeTestFile(tmpFile, json); err != nil {
		t.Fatal(err)
	}

	_, err := LoadConfig(tmpFile)
	if err == nil {
		t.Error("expected error when neither discovery nor servers are set")
	}
}

func writeTestFile(path, content string) error {
	return os.WriteFile(path, []byte(content), 0644)
}
