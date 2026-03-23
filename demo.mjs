/**
 * demo.mjs — Integrated JanworkVM demo.
 *
 * Full architecture (vm.md):
 *
 *   ┌── Host (macOS) ─────────────────┐     ┌── Guest VM (Linux) ─────────┐
 *   │  demo.mjs                        │     │  Ubuntu (rootfs.img)        │
 *   │  ├─ Swift addon → Virtualization │     │  ├─ systemd                 │
 *   │  │   createVM / startVM / vsock  │     │  └─ /smol/bin/sdk-daemon    │
 *   │  └─ RPCClient                    │────→│     (our Rust janworkd)      │
 *   │      via vm.connectGuest()       │vsock│     listens on vsock:9100   │
 *   │      via vm.rpcCall()            │     │                             │
 *   └─────────────────────────────────┘     └─────────────────────────────┘
 *
 * Modes:
 *   node demo.mjs              # VM + vsock RPC (full integration)
 *   node demo.mjs --tcp        # VM + local daemon via TCP (for debugging)
 *   node demo.mjs --skip-vm    # No VM, local daemon via TCP only
 */
import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { existsSync, copyFileSync } from 'fs';
import { spawn as cpSpawn } from 'child_process';

import { RPCClient } from './rpc-client.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const BUNDLE_PATH = join(__dirname, 'bundle');
const DAEMON_BIN = join(__dirname, 'daemon/target/debug/janworkd');
const DAEMON_PORT = 9100;

const skipVM = process.argv.includes('--skip-vm');
const useTcp = process.argv.includes('--tcp');

const sleep = ms => new Promise(r => setTimeout(r, ms));
const sep = () => console.log('\x1b[90m' + '─'.repeat(60) + '\x1b[0m');

// ── Load Swift addon ──
let vm;
if (!skipVM) {
    const native = require('./build/smolvm.node');
    vm = native.vm;
}

async function main() {
    console.log('\x1b[1m=== JanworkVM Integrated Demo ===\x1b[0m');
    const mode = skipVM ? 'TCP only (no VM)' : useTcp ? 'VM + TCP daemon' : 'VM + vsock (full)';
    console.log(`Mode: ${mode}\n`);

    let daemon; // local daemon process (for --tcp and --skip-vm modes)

    // ══════════════════════════════════════════════════════════════
    // Phase 1: VM Setup
    // ══════════════════════════════════════════════════════════════

    if (vm) {
        console.log('\x1b[1m[Phase 1] VM Setup\x1b[0m');
        sep();

        const tier = vm.getMemoryTier();
        const host = vm.getHostMemoryInfo();
        console.log(`Host: ${host.physicalMemoryGB}GB RAM, tier max=${tier.maxGB}GB`);

        // createVM
        await vm.createVM(BUNDLE_PATH, 10);

        // Check rootfs.img — must be a UEFI-bootable Ubuntu image
        // prepared by: ./get-base-image.sh && ./customize-rootfs.sh rootfs.img
        const rootfsPath = join(BUNDLE_PATH, 'rootfs.img');
        const rootfsSrc = join(__dirname, 'rootfs.img');
        if (!existsSync(rootfsPath)) {
            if (existsSync(rootfsSrc)) {
                copyFileSync(rootfsSrc, rootfsPath);
                console.log('  Copied rootfs.img from vm/ directory');
            } else {
                console.log('\x1b[33m');
                console.log('  rootfs.img not found. Prepare it first:');
                console.log('');
                console.log('    ./get-base-image.sh');
                console.log('    cd daemon && ./build-image.sh --build-only && cd ..');
                console.log('    ./customize-rootfs.sh rootfs.img');
                console.log('    mkdir -p bundle && cp rootfs.img bundle/');
                console.log('');
                console.log('  Or run without VM:  node demo.mjs --skip-vm');
                console.log('\x1b[0m');
                process.exit(1);
            }
        }

        // startVM — 3-disk UEFI boot
        const memGB = tier.maxGB;
        console.log(`\nStarting VM (${memGB}GB, 3 disks, UEFI boot)...`);
        try {
            await vm.startVM(BUNDLE_PATH, memGB, 'auto');
            console.log('  VM state:', vm.getStatus().state);
        } catch (e) {
            console.log('  VM start:', e.message ?? e);
        }

        sep();
        console.log('');
    }

    // ══════════════════════════════════════════════════════════════
    // Phase 2: Connect to daemon (vsock or TCP)
    // ══════════════════════════════════════════════════════════════

    console.log('\x1b[1m[Phase 2] Connect to Guest Daemon\x1b[0m');
    sep();

    const rpc = new RPCClient();
    rpc.onStdout = (pid, data) => console.log(`  \x1b[32m[stdout:${pid}]\x1b[0m ${data}`);
    rpc.onStderr = (pid, data) => console.log(`  \x1b[33m[stderr:${pid}]\x1b[0m ${data}`);
    rpc.onExit = (pid, code) => console.log(`  \x1b[90m[exit:${pid}]\x1b[0m code=${code}`);

    if (!skipVM && !useTcp) {
        // ── vsock path: daemon runs INSIDE the VM ──
        console.log('Waiting for guest daemon on vsock port 9100...');
        console.log('  (daemon starts from /usr/local/bin/sdk-daemon inside the VM)');
        console.log('  (first boot may take 60-90s while guest OS initializes)');

        // Show VM console output while waiting so the user can see boot progress
        let consoleInterval;
        let lastConsoleLen = 0;
        if (vm) {
            consoleInterval = setInterval(() => {
                const tail = vm.getConsoleTail();
                if (tail && tail.length > lastConsoleLen) {
                    const newLines = tail.slice(lastConsoleLen).split('\n').filter(Boolean);
                    for (const l of newLines.slice(-3)) {
                        console.log(`  \x1b[90m[guest] ${l.slice(0, 120)}\x1b[0m`);
                    }
                    lastConsoleLen = tail.length;
                }
            }, 2000);
        }

        try {
            await rpc.connectVsock(vm, DAEMON_PORT, { timeout: 120000, retryInterval: 1000 });
        } catch (e) {
            console.log(`  vsock connect failed: ${e.message}`);
            console.log('  Falling back to TCP mode (starting local daemon)...');
            daemon = await startLocalDaemon();
            await rpc.connectTcp('127.0.0.1', DAEMON_PORT);
        } finally {
            if (consoleInterval) clearInterval(consoleInterval);
        }
    } else {
        // ── TCP path: start daemon locally ──
        daemon = await startLocalDaemon();
        await rpc.connectTcp('127.0.0.1', DAEMON_PORT);
    }

    sep();
    console.log('');

    // ══════════════════════════════════════════════════════════════
    // Phase 3: RPC Calls (same API regardless of transport)
    // ══════════════════════════════════════════════════════════════

    console.log('\x1b[1m[Phase 3] RPC Calls\x1b[0m');
    sep();

    // installSdk (vm.md §7.3)
    console.log('installSdk...');
    const sdk = await rpc.installSdk('/sdk/claude-code', '1.0.42');
    console.log(`  → v${sdk.version}`);

    // addApprovedOauthToken (vm.md §9.3)
    console.log('addApprovedOauthToken...');
    await rpc.addApprovedOauthToken('sk-ant-api03-demo-xxxxx');
    console.log('  → token injected');

    // getMemoryInfo (vm.md §10)
    const mem = await rpc.getMemoryInfo();
    console.log(`getMemoryInfo → total=${(mem.totalBytes/1e9).toFixed(1)}GB free=${(mem.freeBytes/1e9).toFixed(1)}GB`);

    console.log('');

    // spawn process (vm.md §7.4)
    console.log('spawn "echo" process...');
    await rpc.spawn('s1', 'echo-test', 'echo', ['Hello from JanworkVM guest!']);
    await sleep(300);
    let st = await rpc.isProcessRunning('s1');
    console.log(`  → running=${st.running} exitCode=${st.exitCode}`);

    console.log('');
    console.log('spawn process with env...');
    await rpc.spawn('s2', 'env-test', '/bin/sh',
        ['-c', 'echo "USER=$USER CLAUDE=$CLAUDE_VER"'],
        '/tmp', { USER: 'claude', CLAUDE_VER: '1.0.42' });
    await sleep(300);
    st = await rpc.isProcessRunning('s2');
    console.log(`  → exitCode=${st.exitCode}`);

    console.log('');

    // readFile (vm.md §4)
    console.log('readFile /etc/hosts...');
    try {
        const f = await rpc.readFile('s1', '/etc/hosts');
        const preview = f.content.split('\n').filter(Boolean).slice(0, 2).join(' | ');
        console.log(`  → "${preview}"`);
    } catch (e) {
        console.log(`  → ${e.message}`);
    }

    sep();
    console.log('');

    // ══════════════════════════════════════════════════════════════
    // Phase 4: Shutdown
    // ══════════════════════════════════════════════════════════════

    console.log('\x1b[1m[Phase 4] Shutdown\x1b[0m');
    sep();

    if (vm) {
        const tail = vm.getConsoleTail();
        if (tail) {
            const lines = tail.split('\n').filter(Boolean).slice(-3);
            console.log('VM console tail:');
            lines.forEach(l => console.log(`  ${l}`));
        }
    }

    rpc.disconnect();
    if (daemon) {
        daemon.kill('SIGTERM');
        await new Promise(r => daemon.on('close', r));
        console.log('Local daemon stopped');
    }
    if (vm?.isRunning()) {
        try { await vm.stopVM(true); } catch {}
        console.log('VM stopped');
    }

    sep();
    console.log('\n\x1b[1m=== Demo Complete ===\x1b[0m');
    if (vm) console.log('Final status:', vm.getStatus());
}

// ── Helper: start local daemon process ──

async function startLocalDaemon() {
    if (!existsSync(DAEMON_BIN)) {
        console.log('Building daemon...');
        await new Promise((resolve, reject) => {
            const cargo = process.env.HOME + '/.cargo/bin/cargo';
            const b = cpSpawn(cargo, ['build'], {
                cwd: join(__dirname, 'daemon'),
                stdio: ['ignore', 'pipe', 'pipe'],
            });
            let err = '';
            b.stderr.on('data', d => err += d);
            b.on('close', code => code === 0 ? resolve() : reject(new Error(err)));
        });
    }

    const daemon = cpSpawn(DAEMON_BIN, [], { stdio: ['ignore', 'pipe', 'pipe'] });
    daemon.stdout.on('data', d => {
        for (const l of d.toString().split('\n').filter(Boolean))
            console.log(`  \x1b[36m[guest]\x1b[0m ${l}`);
    });
    daemon.stderr.on('data', d => {
        for (const l of d.toString().split('\n').filter(Boolean))
            console.log(`  \x1b[36m[guest]\x1b[0m ${l}`);
    });
    await sleep(500);
    console.log(`Local daemon started (pid=${daemon.pid})`);
    return daemon;
}

main().catch(err => {
    console.error('Fatal:', err);
    process.exit(1);
});
