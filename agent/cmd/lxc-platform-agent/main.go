package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"gopkg.in/yaml.v3"
)

type Config struct {
	AK                   string `yaml:"ak"`
	SK                   string `yaml:"sk"`
	SignatureScope       string `yaml:"signature_scope"`
	AuthTimestampSkewSec int    `yaml:"auth_timestamp_skew_seconds"`

	ListenAddr  string `yaml:"listen_addr"`
	MetricsPath string `yaml:"metrics_path"`
	APIBasePath string `yaml:"api_base_path"`

	ContainerInterface string `yaml:"container_interface"`
	PlatformStateDir   string `yaml:"platform_state_dir"`
	ConfigDir          string `yaml:"config_dir"`
	ImageDir           string `yaml:"image_dir"`
	StateFile          string `yaml:"state_file"`
}

type CounterState struct {
	LastRx       uint64 `json:"last_rx"`
	LastTx       uint64 `json:"last_tx"`
	CumulativeRx uint64 `json:"cumulative_rx"`
	CumulativeTx uint64 `json:"cumulative_tx"`
}

type AgentState struct {
	Counters map[string]CounterState `json:"counters"`
}

type PlatformContainer struct {
	ID        string `json:"id"`
	Container string `json:"container"`
	Route     string `json:"route"`
}

type ContainerMetrics struct {
	ID                   string  `json:"id"`
	Container            string  `json:"container"`
	Route                string  `json:"route"`
	Running              bool    `json:"running"`
	CPUSeconds           float64 `json:"cpu_seconds"`
	MemoryBytes          uint64  `json:"memory_bytes"`
	DiskTotalBytes       uint64  `json:"disk_total_bytes"`
	DiskUsedBytes        uint64  `json:"disk_used_bytes"`
	DiskFreeBytes        uint64  `json:"disk_free_bytes"`
	NetRxBytes           uint64  `json:"net_rx_bytes"`
	NetTxBytes           uint64  `json:"net_tx_bytes"`
	NetRxCumulativeBytes uint64  `json:"net_rx_cumulative_bytes"`
	NetTxCumulativeBytes uint64  `json:"net_tx_cumulative_bytes"`
	Error                string  `json:"error,omitempty"`
}

type Payload struct {
	Hostname    string             `json:"hostname"`
	CollectedAt string             `json:"collected_at"`
	Containers  []ContainerMetrics `json:"containers"`
}

type Agent struct {
	cfg Config

	collectMu sync.Mutex

	stateMu sync.Mutex
	state   *AgentState

	mu               sync.RWMutex
	latest           Payload
	lastCollectErr   string
	lastCollectEpoch int64
}

func main() {
	cfgPath := flag.String("config", "config.yaml", "path to config yaml")
	flag.Parse()

	cfg, err := loadConfig(*cfgPath)
	if err != nil {
		fatalf("load config failed: %v", err)
	}

	state, err := loadAgentState(cfg.StateFile)
	if err != nil {
		fatalf("load state failed: %v", err)
	}
	agent := &Agent{cfg: cfg, state: state}

	srv := newServer(cfg, agent)
	serverErrCh := make(chan error, 1)
	go func() {
		logf("serving metrics and API on %s", cfg.ListenAddr)
		err := srv.ListenAndServe()
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErrCh <- err
			return
		}
		serverErrCh <- nil
	}()

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	select {
	case sig := <-sigCh:
		logf("received signal %s, shutting down", sig.String())
	case err := <-serverErrCh:
		if err != nil {
			fatalf("http server failed: %v", err)
		}
		return
	}

	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logf("http shutdown failed: %v", err)
	}

	agent.stateMu.Lock()
	if err := saveAgentState(cfg.StateFile, agent.state); err != nil {
		logf("save state failed: %v", err)
	}
	agent.stateMu.Unlock()
}

func (a *Agent) collectOnce() error {
	cfg := a.cfg

	pcs, err := loadPlatformContainers(cfg.PlatformStateDir)
	if err != nil {
		a.setCollectError(err)
		return fmt.Errorf("load platform containers: %w", err)
	}

	metrics := make([]ContainerMetrics, 0, len(pcs))
	a.stateMu.Lock()
	for _, c := range pcs {
		m := collectOne(cfg, c, a.state)
		metrics = append(metrics, m)
	}

	if err := saveAgentState(cfg.StateFile, a.state); err != nil {
		a.stateMu.Unlock()
		a.setCollectError(err)
		return fmt.Errorf("save state: %w", err)
	}
	a.stateMu.Unlock()

	host, _ := os.Hostname()
	payload := Payload{
		Hostname:    host,
		CollectedAt: time.Now().UTC().Format(time.RFC3339),
		Containers:  metrics,
	}

	a.mu.Lock()
	a.latest = payload
	a.lastCollectErr = ""
	a.lastCollectEpoch = time.Now().Unix()
	a.mu.Unlock()

	logf("collected %d container metrics", len(metrics))
	return nil
}

func (a *Agent) refreshSnapshot() (Payload, string, int64, error) {
	a.collectMu.Lock()
	defer a.collectMu.Unlock()

	if err := a.collectOnce(); err != nil {
		p, lastErr, epoch := a.snapshot()
		return p, lastErr, epoch, err
	}
	p, lastErr, epoch := a.snapshot()
	return p, lastErr, epoch, nil
}

func (a *Agent) setCollectError(err error) {
	a.mu.Lock()
	a.lastCollectErr = err.Error()
	a.lastCollectEpoch = time.Now().Unix()
	a.mu.Unlock()
}

func (a *Agent) snapshot() (Payload, string, int64) {
	a.mu.RLock()
	defer a.mu.RUnlock()
	copyContainers := append([]ContainerMetrics(nil), a.latest.Containers...)
	p := a.latest
	p.Containers = copyContainers
	return p, a.lastCollectErr, a.lastCollectEpoch
}

func collectOne(cfg Config, c PlatformContainer, state *AgentState) ContainerMetrics {
	m := ContainerMetrics{
		ID:        c.ID,
		Container: c.Container,
		Route:     c.Route,
	}

	running, err := isContainerRunning(c.Container)
	if err != nil {
		m.Error = err.Error()
		return m
	}
	m.Running = running

	m.DiskTotalBytes = imageSizeBytes(cfg.ImageDir, c.Container)

	if !running {
		cs := state.Counters[c.Container]
		m.NetRxCumulativeBytes = cs.CumulativeRx
		m.NetTxCumulativeBytes = cs.CumulativeTx
		return m
	}

	m.DiskUsedBytes, m.DiskFreeBytes = mountedDiskUsage(c.Container)

	cpuSec, memBytes, infoErr := readCPUAndMemory(c.Container)
	if infoErr != nil {
		m.Error = infoErr.Error()
	}
	m.CPUSeconds = cpuSec
	m.MemoryBytes = memBytes

	rx, tx, netErr := readNetBytes(c.Container, cfg.ContainerInterface)
	if netErr != nil {
		if m.Error == "" {
			m.Error = netErr.Error()
		} else {
			m.Error = m.Error + "; " + netErr.Error()
		}
		return m
	}
	m.NetRxBytes = rx
	m.NetTxBytes = tx

	cs := state.Counters[c.Container]
	if cs.CumulativeRx == 0 && cs.CumulativeTx == 0 && cs.LastRx == 0 && cs.LastTx == 0 {
		cs.CumulativeRx = rx
		cs.CumulativeTx = tx
	} else {
		if rx >= cs.LastRx {
			cs.CumulativeRx += rx - cs.LastRx
		} else {
			cs.CumulativeRx += rx
		}
		if tx >= cs.LastTx {
			cs.CumulativeTx += tx - cs.LastTx
		} else {
			cs.CumulativeTx += tx
		}
	}
	cs.LastRx = rx
	cs.LastTx = tx
	state.Counters[c.Container] = cs

	m.NetRxCumulativeBytes = cs.CumulativeRx
	m.NetTxCumulativeBytes = cs.CumulativeTx
	return m
}

func loadConfig(path string) (Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Config{}, err
	}
	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return Config{}, err
	}

	if cfg.AuthTimestampSkewSec <= 0 {
		cfg.AuthTimestampSkewSec = 300
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":9108"
	}
	if cfg.MetricsPath == "" {
		cfg.MetricsPath = "/metrics"
	}
	if cfg.APIBasePath == "" {
		cfg.APIBasePath = "/api/v1"
	}
	if !strings.HasPrefix(cfg.MetricsPath, "/") {
		cfg.MetricsPath = "/" + cfg.MetricsPath
	}
	if !strings.HasPrefix(cfg.APIBasePath, "/") {
		cfg.APIBasePath = "/" + cfg.APIBasePath
	}
	cfg.MetricsPath = strings.TrimRight(cfg.MetricsPath, "/")
	if cfg.MetricsPath == "" {
		cfg.MetricsPath = "/metrics"
	}
	cfg.APIBasePath = strings.TrimRight(cfg.APIBasePath, "/")
	if cfg.APIBasePath == "" {
		cfg.APIBasePath = "/api/v1"
	}
	if cfg.ContainerInterface == "" {
		cfg.ContainerInterface = "eth0"
	}
	if cfg.PlatformStateDir == "" {
		cfg.PlatformStateDir = "/opt/lxc-platform/runtime/state/containers"
	}
	if cfg.ConfigDir == "" {
		cfg.ConfigDir = "/opt/lxc-platform/lxc.d"
	}
	if cfg.ImageDir == "" {
		cfg.ImageDir = "/opt/lxc-platform/runtime/images"
	}
	if cfg.StateFile == "" {
		cfg.StateFile = "/opt/lxc-platform/runtime/state/agent/lxc-platform-agent-state.json"
	}

	return cfg, nil
}

func newServer(cfg Config, a *Agent) *http.Server {
	mux := http.NewServeMux()

	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":"ok"}`)
	})

	authWrap := func(h http.HandlerFunc) http.Handler {
		return withAKSKAuth(cfg, h)
	}

	mux.Handle(cfg.MetricsPath, authWrap(func(w http.ResponseWriter, _ *http.Request) {
		payload, _, _, err := a.refreshSnapshot()
		if err != nil {
			http.Error(w, fmt.Sprintf("collect failed: %v", err), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		writePrometheusMetrics(w, payload)
	}))

	mux.Handle(cfg.APIBasePath+"/metrics", authWrap(func(w http.ResponseWriter, _ *http.Request) {
		payload, _, _, err := a.refreshSnapshot()
		if err != nil {
			http.Error(w, fmt.Sprintf("collect failed: %v", err), http.StatusInternalServerError)
			return
		}
		writeJSON(w, payload)
	}))

	mux.Handle(cfg.APIBasePath+"/containers", authWrap(func(w http.ResponseWriter, _ *http.Request) {
		payload, _, _, err := a.refreshSnapshot()
		if err != nil {
			http.Error(w, fmt.Sprintf("collect failed: %v", err), http.StatusInternalServerError)
			return
		}
		writeJSON(w, payload.Containers)
	}))

	mux.Handle(cfg.APIBasePath+"/status", authWrap(func(w http.ResponseWriter, _ *http.Request) {
		payload, collectErr, collectEpoch := a.snapshot()
		status := map[string]any{
			"hostname":           payload.Hostname,
			"collected_at":       payload.CollectedAt,
			"container_count":    len(payload.Containers),
			"last_collect_epoch": collectEpoch,
			"last_collect_error": collectErr,
		}
		writeJSON(w, status)
	}))

	mux.Handle(cfg.APIBasePath+"/configs", authWrap(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
			items, err := listConfigFiles(cfg.ConfigDir)
			if err != nil {
				http.Error(w, fmt.Sprintf("list config files failed: %v", err), http.StatusInternalServerError)
				return
			}
			writeJSON(w, map[string]any{"items": items})
		case http.MethodPost:
			id, content, err := decodeConfigBody(r)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if err := saveConfigYAML(cfg.ConfigDir, id, content, true); err != nil {
				if errors.Is(err, os.ErrExist) {
					http.Error(w, err.Error(), http.StatusConflict)
					return
				}
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			writeJSON(w, map[string]any{"id": id, "path": filepath.Join(cfg.ConfigDir, id+".yaml")})
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}))

	mux.Handle(cfg.APIBasePath+"/configs/", authWrap(func(w http.ResponseWriter, r *http.Request) {
		id, ok := configIDFromPath(cfg.APIBasePath+"/configs/", r.URL.Path)
		if !ok {
			http.Error(w, "invalid config id", http.StatusBadRequest)
			return
		}

		switch r.Method {
		case http.MethodGet:
			info, err := readConfigYAML(cfg.ConfigDir, id)
			if err != nil {
				if errors.Is(err, os.ErrNotExist) {
					http.Error(w, "config not found", http.StatusNotFound)
					return
				}
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			writeJSON(w, info)
		case http.MethodPut:
			_, content, err := decodeConfigBody(r)
			if err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if err := saveConfigYAML(cfg.ConfigDir, id, content, false); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			writeJSON(w, map[string]any{"id": id, "path": filepath.Join(cfg.ConfigDir, id+".yaml")})
		case http.MethodDelete:
			if err := deleteConfigYAML(cfg.ConfigDir, id); err != nil {
				if errors.Is(err, os.ErrNotExist) {
					http.Error(w, "config not found", http.StatusNotFound)
					return
				}
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	}))

	mux.Handle(cfg.APIBasePath+"/states", authWrap(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		items, err := listStateFiles(cfg.PlatformStateDir)
		if err != nil {
			http.Error(w, fmt.Sprintf("list states failed: %v", err), http.StatusInternalServerError)
			return
		}
		writeJSON(w, map[string]any{"items": items})
	}))

	mux.Handle(cfg.APIBasePath+"/states/", authWrap(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		id, ok := configIDFromPath(cfg.APIBasePath+"/states/", r.URL.Path)
		if !ok {
			http.Error(w, "invalid state id", http.StatusBadRequest)
			return
		}

		st, err := readStateJSON(cfg.PlatformStateDir, id)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				http.Error(w, "state not found", http.StatusNotFound)
				return
			}
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		writeJSON(w, st)
	}))

	return &http.Server{
		Addr:         cfg.ListenAddr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 20 * time.Second,
		IdleTimeout:  60 * time.Second,
	}
}

func withAKSKAuth(cfg Config, next http.HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		if err != nil {
			http.Error(w, "read request body failed", http.StatusBadRequest)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))

		if err := verifyAKSK(cfg, r, body); err != nil {
			w.Header().Set("WWW-Authenticate", `Basic realm="lxc-platform-agent"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func verifyAKSK(cfg Config, r *http.Request, body []byte) error {
	if cfg.AK == "" && cfg.SK == "" {
		return nil
	}

	if user, pass, ok := r.BasicAuth(); ok {
		if secureEqual(user, cfg.AK) && secureEqual(pass, cfg.SK) {
			return nil
		}
	}

	ak := r.Header.Get("X-AK")
	timestamp := r.Header.Get("X-Timestamp")
	nonce := r.Header.Get("X-Nonce")
	sig := r.Header.Get("X-Signature")

	if ak == "" || timestamp == "" || nonce == "" || sig == "" {
		return errors.New("missing auth headers")
	}
	if !secureEqual(ak, cfg.AK) {
		return errors.New("invalid ak")
	}

	ts, err := strconv.ParseInt(timestamp, 10, 64)
	if err != nil {
		return fmt.Errorf("invalid timestamp: %w", err)
	}
	now := time.Now().Unix()
	if absInt64(now-ts) > int64(cfg.AuthTimestampSkewSec) {
		return errors.New("timestamp out of range")
	}

	signStr := strings.Join([]string{
		r.Method,
		r.URL.Path,
		timestamp,
		nonce,
		cfg.SignatureScope,
		string(body),
	}, "\n")

	mac := hmac.New(sha256.New, []byte(cfg.SK))
	_, _ = mac.Write([]byte(signStr))
	expected := hex.EncodeToString(mac.Sum(nil))

	if !hmac.Equal([]byte(strings.ToLower(sig)), []byte(expected)) {
		return errors.New("invalid signature")
	}

	return nil
}

func secureEqual(a, b string) bool {
	if len(a) != len(b) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(a), []byte(b)) == 1
}

func absInt64(v int64) int64 {
	if v < 0 {
		return -v
	}
	return v
}

func writePrometheusMetrics(w io.Writer, payload Payload) {
	fmt.Fprintln(w, "# HELP lxc_platform_container_running Container running state (1=running, 0=stopped).")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_running gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_cpu_seconds_total CPU usage seconds from lxc-info.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_cpu_seconds_total gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_memory_bytes Container memory usage in bytes.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_memory_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_disk_total_bytes Container image total bytes.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_disk_total_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_disk_used_bytes Container rootfs used bytes.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_disk_used_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_disk_free_bytes Container rootfs free bytes.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_disk_free_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_network_receive_bytes Current rx bytes read from container interface.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_network_receive_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_network_transmit_bytes Current tx bytes read from container interface.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_network_transmit_bytes gauge")
	fmt.Fprintln(w, "# HELP lxc_platform_container_network_receive_cumulative_bytes Cumulative rx bytes across restarts.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_network_receive_cumulative_bytes counter")
	fmt.Fprintln(w, "# HELP lxc_platform_container_network_transmit_cumulative_bytes Cumulative tx bytes across restarts.")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_network_transmit_cumulative_bytes counter")
	fmt.Fprintln(w, "# HELP lxc_platform_container_collect_error Container collection error (1=has error).")
	fmt.Fprintln(w, "# TYPE lxc_platform_container_collect_error gauge")

	for _, c := range payload.Containers {
		labels := metricLabels(payload.Hostname, c)

		running := 0.0
		if c.Running {
			running = 1
		}
		writeGauge(w, "lxc_platform_container_running", labels, running)
		writeGauge(w, "lxc_platform_container_cpu_seconds_total", labels, c.CPUSeconds)
		writeGauge(w, "lxc_platform_container_memory_bytes", labels, float64(c.MemoryBytes))
		writeGauge(w, "lxc_platform_container_disk_total_bytes", labels, float64(c.DiskTotalBytes))
		writeGauge(w, "lxc_platform_container_disk_used_bytes", labels, float64(c.DiskUsedBytes))
		writeGauge(w, "lxc_platform_container_disk_free_bytes", labels, float64(c.DiskFreeBytes))
		writeGauge(w, "lxc_platform_container_network_receive_bytes", labels, float64(c.NetRxBytes))
		writeGauge(w, "lxc_platform_container_network_transmit_bytes", labels, float64(c.NetTxBytes))
		writeGauge(w, "lxc_platform_container_network_receive_cumulative_bytes", labels, float64(c.NetRxCumulativeBytes))
		writeGauge(w, "lxc_platform_container_network_transmit_cumulative_bytes", labels, float64(c.NetTxCumulativeBytes))

		hasErr := 0.0
		if c.Error != "" {
			hasErr = 1
		}
		writeGauge(w, "lxc_platform_container_collect_error", labels, hasErr)
	}
}

func metricLabels(hostname string, c ContainerMetrics) map[string]string {
	return map[string]string{
		"hostname":  hostname,
		"id":        c.ID,
		"container": c.Container,
		"route":     c.Route,
	}
}

func writeGauge(w io.Writer, name string, labels map[string]string, v float64) {
	fmt.Fprintf(w, "%s{hostname=\"%s\",id=\"%s\",container=\"%s\",route=\"%s\"} %v\n",
		name,
		escapeLabelValue(labels["hostname"]),
		escapeLabelValue(labels["id"]),
		escapeLabelValue(labels["container"]),
		escapeLabelValue(labels["route"]),
		v,
	)
}

func escapeLabelValue(s string) string {
	s = strings.ReplaceAll(s, `\\`, `\\\\`)
	s = strings.ReplaceAll(s, `"`, `\\"`)
	s = strings.ReplaceAll(s, "\n", `\\n`)
	return s
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		http.Error(w, "encode response failed", http.StatusInternalServerError)
	}
}

type ConfigYAMLInfo struct {
	ID        string `json:"id"`
	Path      string `json:"path"`
	Content   string `json:"content,omitempty"`
	SizeBytes int64  `json:"size_bytes"`
	UpdatedAt string `json:"updated_at"`
}

func listConfigFiles(dir string) ([]ConfigYAMLInfo, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.yaml"))
	if err != nil {
		return nil, err
	}
	out := make([]ConfigYAMLInfo, 0, len(files))
	for _, f := range files {
		st, err := os.Stat(f)
		if err != nil {
			continue
		}
		id := strings.TrimSuffix(filepath.Base(f), ".yaml")
		out = append(out, ConfigYAMLInfo{
			ID:        id,
			Path:      f,
			SizeBytes: st.Size(),
			UpdatedAt: st.ModTime().UTC().Format(time.RFC3339),
		})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out, nil
}

func readConfigYAML(dir, id string) (ConfigYAMLInfo, error) {
	if !validConfigID(id) {
		return ConfigYAMLInfo{}, fmt.Errorf("invalid config id")
	}
	p := filepath.Join(dir, id+".yaml")
	data, err := os.ReadFile(p)
	if err != nil {
		return ConfigYAMLInfo{}, err
	}
	st, err := os.Stat(p)
	if err != nil {
		return ConfigYAMLInfo{}, err
	}
	return ConfigYAMLInfo{
		ID:        id,
		Path:      p,
		Content:   string(data),
		SizeBytes: st.Size(),
		UpdatedAt: st.ModTime().UTC().Format(time.RFC3339),
	}, nil
}

func saveConfigYAML(dir, id, content string, createOnly bool) error {
	if !validConfigID(id) {
		return fmt.Errorf("invalid config id")
	}
	content = strings.TrimSpace(content)
	if content == "" {
		return fmt.Errorf("config content is empty")
	}
	if len(content) > 1<<20 {
		return fmt.Errorf("config content too large")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	p := filepath.Join(dir, id+".yaml")
	if createOnly {
		if _, err := os.Stat(p); err == nil {
			return fmt.Errorf("%w: %s", os.ErrExist, p)
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, []byte(content+"\n"), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, p)
}

func deleteConfigYAML(dir, id string) error {
	if !validConfigID(id) {
		return fmt.Errorf("invalid config id")
	}
	p := filepath.Join(dir, id+".yaml")
	return os.Remove(p)
}

func configIDFromPath(prefix, path string) (string, bool) {
	id := strings.TrimPrefix(path, prefix)
	id = strings.TrimSpace(id)
	if id == "" || strings.Contains(id, "/") {
		return "", false
	}
	if !validConfigID(id) {
		return "", false
	}
	return id, true
}

var configIDRegexp = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$`)

func validConfigID(id string) bool {
	return configIDRegexp.MatchString(id)
}

func decodeConfigBody(r *http.Request) (id string, content string, err error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err != nil {
		return "", "", fmt.Errorf("read body failed: %w", err)
	}
	if len(bytes.TrimSpace(body)) == 0 {
		return "", "", fmt.Errorf("empty request body")
	}

	ct := strings.ToLower(strings.TrimSpace(r.Header.Get("Content-Type")))
	if strings.Contains(ct, "application/json") {
		var req struct {
			ID      string `json:"id"`
			Content string `json:"content"`
		}
		if err := json.Unmarshal(body, &req); err != nil {
			return "", "", fmt.Errorf("invalid json body: %w", err)
		}
		return strings.TrimSpace(req.ID), req.Content, nil
	}

	return "", string(body), nil
}

func listStateFiles(dir string) ([]map[string]any, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(files))
	for _, f := range files {
		id := strings.TrimSuffix(filepath.Base(f), ".json")
		st, err := readStateJSON(dir, id)
		if err != nil {
			continue
		}
		out = append(out, st)
	}
	sort.Slice(out, func(i, j int) bool {
		iID, _ := out[i]["id"].(string)
		jID, _ := out[j]["id"].(string)
		return iID < jID
	})
	return out, nil
}

func readStateJSON(dir, id string) (map[string]any, error) {
	if !validConfigID(id) {
		return nil, fmt.Errorf("invalid state id")
	}
	p := filepath.Join(dir, id+".json")
	data, err := os.ReadFile(p)
	if err != nil {
		return nil, err
	}
	out := map[string]any{}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, err
	}
	return out, nil
}

func loadAgentState(path string) (*AgentState, error) {
	out := &AgentState{Counters: map[string]CounterState{}}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return out, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return out, nil
	}
	if err := json.Unmarshal(data, out); err != nil {
		return nil, err
	}
	if out.Counters == nil {
		out.Counters = map[string]CounterState{}
	}
	return out, nil
}

func saveAgentState(path string, st *AgentState) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func loadPlatformContainers(dir string) ([]PlatformContainer, error) {
	files, err := filepath.Glob(filepath.Join(dir, "*.json"))
	if err != nil {
		return nil, err
	}

	out := make([]PlatformContainer, 0, len(files))
	for _, f := range files {
		data, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		var c PlatformContainer
		if err := json.Unmarshal(data, &c); err != nil {
			continue
		}
		if c.Container == "" {
			continue
		}
		out = append(out, c)
	}

	if len(out) > 0 {
		return out, nil
	}

	names, err := execStringLines("lxc-ls", "-1")
	if err != nil {
		return nil, err
	}
	out = make([]PlatformContainer, 0, len(names))
	for _, n := range names {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		out = append(out, PlatformContainer{ID: n, Container: n, Route: n})
	}
	return out, nil
}

func isContainerRunning(ct string) (bool, error) {
	out, err := execString("lxc-info", "-n", ct)
	if err != nil {
		return false, err
	}
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "State:") {
			v := strings.TrimSpace(strings.TrimPrefix(line, "State:"))
			return strings.EqualFold(v, "RUNNING"), nil
		}
	}
	return false, nil
}

func readCPUAndMemory(ct string) (float64, uint64, error) {
	out, err := execString("lxc-info", "-n", ct)
	if err != nil {
		return 0, 0, err
	}

	var cpuSec float64
	var mem uint64
	var hasCPU, hasMem bool

	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "CPU use:") {
			raw := strings.TrimSpace(strings.TrimSuffix(strings.TrimPrefix(line, "CPU use:"), "seconds"))
			if v, err := strconv.ParseFloat(raw, 64); err == nil {
				cpuSec = v
				hasCPU = true
			}
		}
		if strings.HasPrefix(line, "Memory use:") {
			raw := strings.TrimSpace(strings.TrimPrefix(line, "Memory use:"))
			if v, err := parseSizeToBytes(raw); err == nil {
				mem = v
				hasMem = true
			}
		}
	}

	if !hasCPU && !hasMem {
		return 0, 0, fmt.Errorf("cannot parse cpu/memory from lxc-info")
	}
	return cpuSec, mem, nil
}

func readNetBytes(ct, iface string) (uint64, uint64, error) {
	cmd := fmt.Sprintf("cat /sys/class/net/%s/statistics/rx_bytes /sys/class/net/%s/statistics/tx_bytes", iface, iface)
	out, err := execString("lxc-attach", "-n", ct, "--", "sh", "-lc", cmd)
	if err != nil {
		return 0, 0, err
	}
	lines := strings.Fields(out)
	if len(lines) < 2 {
		return 0, 0, fmt.Errorf("unexpected net counter output")
	}
	rx, err := strconv.ParseUint(lines[0], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	tx, err := strconv.ParseUint(lines[1], 10, 64)
	if err != nil {
		return 0, 0, err
	}
	return rx, tx, nil
}

func imageSizeBytes(imageDir, ct string) uint64 {
	p := filepath.Join(imageDir, ct+".img")
	st, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return uint64(st.Size())
}

func mountedDiskUsage(ct string) (used uint64, free uint64) {
	rootfs := filepath.Join("/var/lib/lxc", ct, "rootfs")
	if _, err := os.Stat(rootfs); err != nil {
		return 0, 0
	}

	out, err := execString("df", "-k", rootfs)
	if err != nil {
		return 0, 0
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 2 {
		return 0, 0
	}
	f := strings.Fields(lines[len(lines)-1])
	if len(f) < 4 {
		return 0, 0
	}
	usedKB, err1 := strconv.ParseUint(f[2], 10, 64)
	freeKB, err2 := strconv.ParseUint(f[3], 10, 64)
	if err1 != nil || err2 != nil {
		return 0, 0
	}
	return usedKB * 1024, freeKB * 1024
}

func parseSizeToBytes(s string) (uint64, error) {
	re := regexp.MustCompile(`(?i)^\s*([0-9]+(?:\.[0-9]+)?)\s*([kmgtpe]?i?b?)?\s*$`)
	m := re.FindStringSubmatch(strings.TrimSpace(s))
	if len(m) == 0 {
		return 0, fmt.Errorf("invalid size: %s", s)
	}

	num, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, err
	}

	unit := strings.ToLower(m[2])
	mul := float64(1)
	switch unit {
	case "", "b":
		mul = 1
	case "k", "kb":
		mul = 1000
	case "m", "mb":
		mul = 1000 * 1000
	case "g", "gb":
		mul = 1000 * 1000 * 1000
	case "t", "tb":
		mul = 1000 * 1000 * 1000 * 1000
	case "ki", "kib":
		mul = 1024
	case "mi", "mib":
		mul = 1024 * 1024
	case "gi", "gib":
		mul = 1024 * 1024 * 1024
	case "ti", "tib":
		mul = 1024 * 1024 * 1024 * 1024
	default:
		return 0, fmt.Errorf("unsupported unit: %s", unit)
	}

	if num < 0 {
		return 0, fmt.Errorf("negative size")
	}
	return uint64(math.Round(num * mul)), nil
}

func execString(name string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s %s failed: %w (%s)", name, strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func execStringLines(name string, args ...string) ([]string, error) {
	s, err := execString(name, args...)
	if err != nil {
		return nil, err
	}
	out := []string{}
	for _, line := range strings.Split(s, "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out = append(out, line)
		}
	}
	return out, nil
}

func logf(format string, args ...any) {
	fmt.Printf("[%s] %s\n", time.Now().Format(time.RFC3339), fmt.Sprintf(format, args...))
}

func fatalf(format string, args ...any) {
	logf(format, args...)
	os.Exit(1)
}
