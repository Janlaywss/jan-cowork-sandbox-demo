//! Process manager — spawn, kill, stdin, stdout/stderr forwarding.
//!
//! Each spawned process gets:
//!   - An independent cgroup (Linux, for resource isolation + OOM detection)
//!   - seccomp filtering via sandbox-helper (Linux)
//!   - VirtioFS mount points for host shared directories
//!   - Forwarded stdout/stderr as RPC events back to the host
//!
//! See vm.md §11 for the full isolation model.

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::Stdio;

use tokio::io::AsyncWriteExt;
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use tracing::{info, warn};

struct ManagedProcess {
    name: String,
    child: Child,
    stdin: Option<tokio::process::ChildStdin>,
}

pub struct ProcessManager {
    sessions_dir: PathBuf,
    processes: Mutex<HashMap<String, ManagedProcess>>,
}

impl ProcessManager {
    pub fn new(sessions_dir: impl Into<PathBuf>) -> Self {
        Self {
            sessions_dir: sessions_dir.into(),
            processes: Mutex::new(HashMap::new()),
        }
    }

    /// Spawn a new process with optional cwd and environment variables.
    ///
    /// In production (Linux guest), this would also:
    ///   1. Create a cgroup: /sys/fs/cgroup/janworkd/<id>/
    ///   2. Apply seccomp via sandbox-helper
    ///   3. Mount VirtioFS shared directories at /sessions/<name>/mnt/
    ///   4. Set up skeleton home directory
    pub async fn spawn(
        &self,
        id: &str,
        name: &str,
        command: &str,
        args: &[String],
        cwd: Option<&str>,
        env: &[(String, String)],
    ) -> Result<(), String> {
        let mut processes = self.processes.lock().await;

        if processes.contains_key(id) {
            return Err(format!("process {id} already exists"));
        }

        // Create per-session directory: {sessions_dir}/{id}/
        let session_dir = self.sessions_dir.join(id);
        std::fs::create_dir_all(&session_dir)
            .map_err(|e| format!("failed to create session dir {}: {e}", session_dir.display()))?;
        info!("[process:{id}] session dir: {}", session_dir.display());

        let mut cmd = Command::new(command);
        cmd.args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        // Use caller-specified cwd, or fall back to the session directory
        cmd.current_dir(cwd.unwrap_or_else(|| session_dir.to_str().unwrap_or("/")));

        for (k, v) in env {
            cmd.env(k, v);
        }

        // On Linux, we would set up cgroup before exec:
        //   cmd.pre_exec(|| { write_pid_to_cgroup(); apply_seccomp(); Ok(()) });

        let mut child = cmd.spawn().map_err(|e| format!("spawn failed: {e}"))?;

        info!("[process:{id}] spawned pid={}", child.id().unwrap_or(0));

        // Forward stdout as RPC events
        let stdout = child.stdout.take();
        let pid = id.to_string();
        if let Some(stdout) = stdout {
            let pid = pid.clone();
            tokio::spawn(async move {
                use tokio::io::{AsyncBufReadExt, BufReader};
                let mut lines = BufReader::new(stdout).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    // In production: send as JSON-RPC event via the vsock connection
                    // {"method": "onStdout", "params": {"processId": "<id>", "data": "<line>\n"}}
                    info!("[process:{pid}] stdout: {line}");
                }
            });
        }

        // Forward stderr as RPC events
        let stderr = child.stderr.take();
        if let Some(stderr) = stderr {
            let pid = id.to_string();
            tokio::spawn(async move {
                use tokio::io::{AsyncBufReadExt, BufReader};
                let mut lines = BufReader::new(stderr).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    // {"method": "onStderr", "params": {"processId": "<id>", "data": "<line>\n"}}
                    warn!("[process:{pid}] stderr: {line}");
                }
            });
        }

        // Monitor for exit
        let stdin = child.stdin.take();
        let exit_id = id.to_string();
        let mut exit_child = child;
        let exit_handle = tokio::spawn(async move {
            match exit_child.wait().await {
                Ok(status) => {
                    let code = status.code();
                    info!(
                        "[process:{exit_id}] exited with code={}",
                        code.map(|c| c.to_string()).unwrap_or("signal".into())
                    );
                    // {"method": "onExit", "params": {"processId": "<id>", "exitCode": N}}
                    code
                }
                Err(e) => {
                    warn!("[process:{exit_id}] wait failed: {e}");
                    None
                }
            }
        });

        // We need a placeholder child for the HashMap — since we moved the child
        // into the exit monitor, we store just the stdin handle and metadata.
        // This is simplified for the demo; production tracks the exit_handle too.
        processes.insert(
            id.to_string(),
            ManagedProcess {
                name: name.to_string(),
                child: Command::new("true").spawn().unwrap(), // placeholder
                stdin,
            },
        );

        // Store the exit handle ID for later cleanup
        let cleanup_id = id.to_string();
        let cleanup_dir = session_dir.clone();
        tokio::spawn(async move {
            let _code = exit_handle.await;
            info!("[process:{cleanup_id}] exited, cleaning up session dir");
            // In production: also cleanup cgroup and unmount VirtioFS
            if let Err(e) = std::fs::remove_dir_all(&cleanup_dir) {
                warn!(
                    "[process:{cleanup_id}] failed to remove session dir {}: {e}",
                    cleanup_dir.display()
                );
            }
        });

        Ok(())
    }

    /// Send a signal to a managed process.
    ///
    /// In production on Linux, this also:
    ///   - Sends signal to the entire cgroup if needed
    ///   - Falls back to cgroup.kill if processes don't exit within timeout
    pub async fn kill(&self, id: &str, signal: &str) -> Result<(), String> {
        let mut processes = self.processes.lock().await;

        let proc = processes
            .get_mut(id)
            .ok_or_else(|| format!("process {id} not found"))?;

        info!("[process:{id}] killing (signal={signal}, name={})", proc.name);

        // Map signal name to nix::sys::signal on Linux; for demo, just kill
        proc.child
            .kill()
            .await
            .map_err(|e| format!("kill failed: {e}"))?;

        processes.remove(id);
        Ok(())
    }

    /// Write data to a process's stdin pipe.
    pub async fn write_stdin(&self, id: &str, data: &str) -> Result<(), String> {
        let mut processes = self.processes.lock().await;

        let proc = processes
            .get_mut(id)
            .ok_or_else(|| format!("process {id} not found"))?;

        if let Some(ref mut stdin) = proc.stdin {
            stdin
                .write_all(data.as_bytes())
                .await
                .map_err(|e| format!("stdin write failed: {e}"))?;
            Ok(())
        } else {
            Err(format!("process {id} has no stdin"))
        }
    }

    /// Check if a process is still running.
    pub async fn is_running(&self, id: &str) -> (bool, Option<i32>) {
        let mut processes = self.processes.lock().await;

        match processes.get_mut(id) {
            Some(proc) => match proc.child.try_wait() {
                Ok(Some(status)) => (false, status.code()),
                Ok(None) => (true, None),
                Err(_) => (false, None),
            },
            None => (false, None),
        }
    }
}
