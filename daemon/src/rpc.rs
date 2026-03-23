//! JSON-RPC message types and dispatcher.
//!
//! Wire protocol (vm.md §8.2):
//!   Host sends:  {"id": N, "method": "spawn", "params": {...}}
//!   Guest sends: {"id": N, "result": {...}}          — response
//!                {"method": "onStdout", "params": {...}} — event (no id)

use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tracing::{info, warn};

use crate::network;
use crate::process::ProcessManager;

// ── Wire types ──

#[derive(Debug, Deserialize)]
pub struct Request {
    pub id: Option<u64>,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct Response {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub method: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<Value>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: i32,
    pub message: String,
}

impl Response {
    fn ok(id: Option<u64>, result: Value) -> Self {
        Self { id, result: Some(result), error: None, method: None, params: None }
    }

    fn err(id: Option<u64>, code: i32, msg: impl Into<String>) -> Self {
        Self {
            id,
            result: None,
            error: Some(RpcError { code, message: msg.into() }),
            method: None,
            params: None,
        }
    }

    /// Create an event notification (no id, has method + params).
    pub fn event(method: &str, params: Value) -> Self {
        Self {
            id: None,
            result: None,
            error: None,
            method: Some(method.to_string()),
            params: Some(params),
        }
    }
}

// ── Dispatcher ──

pub struct Dispatcher {
    pm: Arc<ProcessManager>,
}

impl Dispatcher {
    pub fn new(pm: Arc<ProcessManager>) -> Self {
        Self { pm }
    }

    /// Handle a single JSON-RPC line. Returns one or more responses/events.
    pub async fn handle(&self, line: &str) -> Vec<Response> {
        let req: Request = match serde_json::from_str(line) {
            Ok(r) => r,
            Err(e) => {
                warn!("[rpc] parse error: {e}");
                return vec![Response::err(None, -32700, format!("Parse error: {e}"))];
            }
        };

        info!("[wire] reading message: method={}", req.method);

        match req.method.as_str() {
            "spawn" => self.handle_spawn(&req).await,
            "kill" => self.handle_kill(&req).await,
            "writeStdin" => self.handle_write_stdin(&req).await,
            "isRunning" => self.handle_is_running(&req).await,
            "installSdk" => self.handle_install_sdk(&req).await,
            "addApprovedOauthToken" => self.handle_add_token(&req).await,
            "readFile" => self.handle_read_file(&req).await,
            "getMemoryInfo" => self.handle_memory_info(&req).await,
            other => {
                warn!("[rpc] unknown method: {other}");
                vec![Response::err(req.id, -32601, format!("Unknown method: {other}"))]
            }
        }
    }

    // ── spawn ──────────────────────────────────────────────────────

    async fn handle_spawn(&self, req: &Request) -> Vec<Response> {
        let id = req.params["id"].as_str().unwrap_or("unknown").to_string();
        let command = req.params["command"].as_str().unwrap_or("").to_string();
        let name = req.params["name"].as_str().unwrap_or(&id).to_string();

        let args: Vec<String> = req.params["args"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();

        let cwd = req.params["cwd"].as_str().map(String::from);

        let env: Vec<(String, String)> = req.params["env"]
            .as_object()
            .map(|m| {
                m.iter()
                    .filter_map(|(k, v)| v.as_str().map(|v| (k.clone(), v.to_string())))
                    .collect()
            })
            .unwrap_or_default();

        // Check allowed domains if provided (network filtering)
        if let Some(domains) = req.params["allowedDomains"].as_array() {
            let domain_list: Vec<&str> = domains.iter().filter_map(|d| d.as_str()).collect();
            info!("[process:{id}] allowed domains: {domain_list:?}");
        }

        info!("[process:{id}] spawning: {command} {args:?} (name={name})");

        match self.pm.spawn(&id, &name, &command, &args, cwd.as_deref(), &env).await {
            Ok(()) => vec![Response::ok(req.id, serde_json::json!({"ok": true}))],
            Err(e) => vec![Response::err(req.id, -1, e)],
        }
    }

    // ── kill ───────────────────────────────────────────────────────

    async fn handle_kill(&self, req: &Request) -> Vec<Response> {
        let id = req.params["id"].as_str().unwrap_or("");
        let signal = req.params["signal"].as_str().unwrap_or("SIGTERM");

        info!("[process:{id}] kill signal={signal}");
        match self.pm.kill(id, signal).await {
            Ok(()) => vec![Response::ok(req.id, serde_json::json!({"ok": true}))],
            Err(e) => vec![Response::err(req.id, -1, e)],
        }
    }

    // ── writeStdin ────────────────────────────────────────────────

    async fn handle_write_stdin(&self, req: &Request) -> Vec<Response> {
        let id = req.params["id"].as_str().unwrap_or("");
        let data = req.params["data"].as_str().unwrap_or("");

        match self.pm.write_stdin(id, data).await {
            Ok(()) => vec![Response::ok(req.id, serde_json::json!({"ok": true}))],
            Err(e) => vec![Response::err(req.id, -1, e)],
        }
    }

    // ── isRunning ─────────────────────────────────────────────────

    async fn handle_is_running(&self, req: &Request) -> Vec<Response> {
        let id = req.params["id"].as_str().unwrap_or("");
        let (running, exit_code) = self.pm.is_running(id).await;
        vec![Response::ok(
            req.id,
            serde_json::json!({"running": running, "exitCode": exit_code}),
        )]
    }

    // ── installSdk ────────────────────────────────────────────────

    async fn handle_install_sdk(&self, req: &Request) -> Vec<Response> {
        let subpath = req.params["sdkSubpath"].as_str().unwrap_or("");
        let version = req.params["version"].as_str().unwrap_or("unknown");

        // In production: copies binary from smol-bin mount to /usr/local/bin/claude
        info!("[janwork] installed SDK binary v{version} to /usr/local/bin/claude (subpath={subpath})");
        vec![Response::ok(req.id, serde_json::json!({"ok": true, "version": "99999222"}))]
    }

    // ── addApprovedOauthToken ─────────────────────────────────────

    async fn handle_add_token(&self, req: &Request) -> Vec<Response> {
        let token = req.params["token"].as_str().unwrap_or("");
        let masked = if token.len() > 8 {
            format!("{}...{}", &token[..4], &token[token.len() - 4..])
        } else {
            "****".to_string()
        };
        info!("[proxy] approved OAuth token: {masked}");
        vec![Response::ok(req.id, serde_json::json!({"ok": true}))]
    }

    // ── readFile ──────────────────────────────────────────────────

    async fn handle_read_file(&self, req: &Request) -> Vec<Response> {
        let path = req.params["filePath"].as_str().unwrap_or("");
        info!("[janwork] readFile: {path}");

        match tokio::fs::read_to_string(path).await {
            Ok(content) => vec![Response::ok(req.id, serde_json::json!({"content": content}))],
            Err(e) => vec![Response::err(req.id, -1, format!("read failed: {e}"))],
        }
    }

    // ── getMemoryInfo ─────────────────────────────────────────────

    async fn handle_memory_info(&self, req: &Request) -> Vec<Response> {
        let (total, free) = read_meminfo().await;
        vec![Response::ok(
            req.id,
            serde_json::json!({"totalBytes": total, "freeBytes": free}),
        )]
    }
}

/// Read memory info from /proc/meminfo (Linux) or fallback to defaults.
async fn read_meminfo() -> (u64, u64) {
    match tokio::fs::read_to_string("/proc/meminfo").await {
        Ok(content) => {
            let mut total: u64 = 0;
            let mut free: u64 = 0;
            for line in content.lines() {
                if let Some(val) = line.strip_prefix("MemTotal:") {
                    total = parse_meminfo_kb(val) * 1024;
                } else if let Some(val) = line.strip_prefix("MemAvailable:") {
                    free = parse_meminfo_kb(val) * 1024;
                }
            }
            if total > 0 {
                return (total, free);
            }
            // Fallback if parsing failed
            (4 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024)
        }
        Err(_) => {
            // Not on Linux (macOS testing) — return placeholder values
            (4 * 1024 * 1024 * 1024, 2 * 1024 * 1024 * 1024)
        }
    }
}

/// Parse a /proc/meminfo value line like "  8052456 kB" → 8052456
fn parse_meminfo_kb(s: &str) -> u64 {
    s.trim()
        .split_whitespace()
        .next()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}
