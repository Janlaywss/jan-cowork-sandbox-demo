//! janworkd — Demo sdk-daemon for JanworkVM.
//!
//! Architecture (vm.md §8, §11):
//!   Host (JanworkVMRPCClient)  ←vsock→  Guest (janworkd)
//!
//! On Linux (inside VM): listens on vsock port for host RPC.
//!   Logs to /dev/hvc0 (virtio console) so output appears in VM serial.
//! On macOS (testing):   listens on TCP localhost:9100.

mod network;
mod process;
mod rpc;

use std::sync::Arc;
use tracing::{info, warn};

use process::ProcessManager;
use rpc::Dispatcher;

const VSOCK_PORT: u32 = 9100;

#[tokio::main]
async fn main() {
    // On Linux (inside VM), redirect logs to /dev/hvc0 (virtio console)
    // so they appear in the host's serial output.
    #[cfg(target_os = "linux")]
    {
        use std::fs::OpenOptions;
        use std::io::Write;

        // Try to open /dev/hvc0 for console output
        if let Ok(mut hvc) = OpenOptions::new().write(true).open("/dev/hvc0") {
            let _ = writeln!(hvc, "[janwork] starting janworkd (Rust daemon)");
        }

        // Set up tracing to write to /dev/hvc0 via a custom writer
        let hvc_writer = HvcWriter::new();
        tracing_subscriber::fmt()
            .with_target(false)
            .with_timer(tracing_subscriber::fmt::time::uptime())
            .with_writer(move || hvc_writer.clone())
            .init();
    }

    #[cfg(not(target_os = "linux"))]
    {
        tracing_subscriber::fmt()
            .with_target(false)
            .with_timer(tracing_subscriber::fmt::time::uptime())
            .init();
    }

    info!("[janwork] starting janworkd");

    let pm = Arc::new(ProcessManager::new());
    let dispatcher = Arc::new(Dispatcher::new(pm.clone()));

    #[cfg(target_os = "linux")]
    {
        listen_vsock(dispatcher).await;
    }

    #[cfg(not(target_os = "linux"))]
    {
        listen_tcp(dispatcher).await;
    }
}

// ── /dev/hvc0 writer for tracing (Linux only) ──

#[cfg(target_os = "linux")]
#[derive(Clone)]
struct HvcWriter {
    fd: Arc<std::sync::Mutex<Option<std::fs::File>>>,
}

#[cfg(target_os = "linux")]
impl HvcWriter {
    fn new() -> Self {
        use std::fs::OpenOptions;
        let file = OpenOptions::new().write(true).open("/dev/hvc0").ok();
        Self {
            fd: Arc::new(std::sync::Mutex::new(file)),
        }
    }
}

#[cfg(target_os = "linux")]
impl std::io::Write for HvcWriter {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        if let Ok(mut guard) = self.fd.lock() {
            if let Some(ref mut f) = *guard {
                return f.write(buf);
            }
        }
        // Fallback to stderr
        std::io::stderr().write(buf)
    }
    fn flush(&mut self) -> std::io::Result<()> {
        if let Ok(mut guard) = self.fd.lock() {
            if let Some(ref mut f) = *guard {
                return f.flush();
            }
        }
        std::io::stderr().flush()
    }
}

// ── TCP listener (macOS testing) ──

#[cfg(not(target_os = "linux"))]
async fn listen_tcp(dispatcher: Arc<Dispatcher>) {
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::TcpListener;

    let addr = format!("127.0.0.1:{VSOCK_PORT}");
    let listener = TcpListener::bind(&addr).await.expect("bind failed");
    info!("[janwork] listening on tcp://{addr} (test mode, simulates vsock)");
    info!("[janwork] connected, waiting for commands");

    loop {
        let (stream, peer) = listener.accept().await.expect("accept failed");
        info!("[janwork] client connected from {peer}");
        let dispatcher = dispatcher.clone();

        tokio::spawn(async move {
            let (reader, mut writer) = stream.into_split();
            let mut lines = BufReader::new(reader).lines();

            while let Ok(Some(line)) = lines.next_line().await {
                let line = line.trim().to_string();
                if line.is_empty() {
                    continue;
                }
                let responses = dispatcher.handle(&line).await;
                for resp in responses {
                    let mut out = serde_json::to_string(&resp).unwrap();
                    out.push('\n');
                    if writer.write_all(out.as_bytes()).await.is_err() {
                        warn!("[janwork] write failed, client disconnected");
                        return;
                    }
                }
            }
            info!("[janwork] client disconnected");
        });
    }
}

// ── vsock listener (Linux, inside VM) ──

#[cfg(target_os = "linux")]
async fn listen_vsock(dispatcher: Arc<Dispatcher>) {
    use std::io::{BufRead, BufReader, Write};
    use vsock::VsockListener;

    let handle = tokio::runtime::Handle::current();

    tokio::task::spawn_blocking(move || {
        // Try multiple times to bind — vsock module may not be loaded yet
        let listener = {
            let mut attempts = 0;
            loop {
                match VsockListener::bind_with_cid_port(vsock::VMADDR_CID_ANY, VSOCK_PORT) {
                    Ok(l) => break l,
                    Err(e) => {
                        attempts += 1;
                        if attempts > 10 {
                            // Fatal: can't bind vsock after retries
                            warn!("[janwork] vsock bind failed after {attempts} attempts: {e}");
                            return;
                        }
                        warn!("[janwork] vsock bind attempt {attempts} failed: {e}, retrying...");
                        std::thread::sleep(std::time::Duration::from_secs(1));
                    }
                }
            }
        };

        info!("[janwork] listening on vsock port {VSOCK_PORT}");
        info!("[janwork] connected, waiting for commands");

        for conn in listener.incoming() {
            let stream = match conn {
                Ok(s) => s,
                Err(e) => {
                    warn!("[janwork] vsock accept error: {e}");
                    continue;
                }
            };
            info!("[janwork] vsock client connected");

            let dispatcher = dispatcher.clone();
            let handle = handle.clone();

            std::thread::spawn(move || {
                let reader_stream = stream.try_clone().expect("vsock clone failed");
                let mut writer = stream;
                let reader = BufReader::new(reader_stream);

                for line_result in reader.lines() {
                    let line = match line_result {
                        Ok(l) if !l.trim().is_empty() => l,
                        Ok(_) => continue,
                        Err(_) => break,
                    };

                    let responses = handle.block_on(dispatcher.handle(line.trim()));
                    for resp in responses {
                        let mut out = serde_json::to_string(&resp).unwrap();
                        out.push('\n');
                        if writer.write_all(out.as_bytes()).is_err() {
                            return;
                        }
                    }
                }
                info!("[janwork] vsock client disconnected");
            });
        }
    })
    .await
    .unwrap();
}
