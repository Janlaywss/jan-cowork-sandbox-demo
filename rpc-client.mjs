/**
 * rpc-client.mjs — JSON-RPC client over TCP.
 *
 * Models the Swift-side JanworkVMRPCClient (vm.md §8) which communicates
 * with the Guest sdk-daemon (janworkd) over vsock.
 *
 * In production:
 *   Host VZVirtioSocketDevice ←vsock→ Guest sdk-daemon
 *
 * In this demo:
 *   Host TCP:9100 ←tcp→ Local janworkd process
 *
 * Wire protocol (newline-delimited JSON):
 *   Request:  {"id": N, "method": "spawn", "params": {...}}\n
 *   Response: {"id": N, "result": {...}}\n
 *   Event:    {"method": "onStdout", "params": {...}}\n
 */
import { createConnection } from 'net';

export class RPCClient {
    #socket = null;
    #buffer = '';
    #requestId = 0;
    #pending = new Map();   // id → { resolve, reject }
    #connected = false;
    #vmAddon = null;        // Swift addon for vsock transport

    // Event callbacks (matches vm.md §8.4)
    onStdout = null;   // (processId, data) => void
    onStderr = null;   // (processId, data) => void
    onExit = null;     // (processId, exitCode, signal) => void
    onError = null;    // (processId, message, fatal) => void

    get isConnected() { return this.#connected; }

    /**
     * Connect via vsock through the Swift VM addon.
     * This is the production path: Host → VZVirtioSocketDevice → Guest daemon.
     */
    async connectVsock(vmAddon, port = 9100, { timeout = 30000, retryInterval = 500 } = {}) {
        this.#vmAddon = vmAddon;
        const deadline = Date.now() + timeout;

        while (Date.now() < deadline) {
            try {
                await vmAddon.connectGuest(port);
                this.#connected = true;
                console.log(`[rpc] connected via vsock port ${port}`);
                return;
            } catch {
                await new Promise(r => setTimeout(r, retryInterval));
            }
        }
        this.#vmAddon = null;  // vsock failed, clear addon ref
        throw new Error(`[rpc] vsock connection timeout after ${timeout}ms`);
    }

    /**
     * Connect via TCP (for local testing without VM).
     */
    connectTcp(host = '127.0.0.1', port = 9100, { timeout = 10000, retries = 20, retryInterval = 500 } = {}) {
        this.#vmAddon = null;  // ensure TCP transport is used
        return new Promise((resolve, reject) => {
            const deadline = Date.now() + timeout;
            let attempt = 0;

            const tryConnect = () => {
                if (Date.now() > deadline) {
                    reject(new Error(`[rpc] connection timeout after ${timeout}ms`));
                    return;
                }

                attempt++;
                const sock = createConnection({ host, port }, () => {
                    this.#socket = sock;
                    this.#connected = true;
                    console.log(`[rpc] connected to ${host}:${port} (TCP)`);
                    resolve();
                });

                sock.setEncoding('utf8');
                sock.on('data', (chunk) => this.#onData(chunk));
                sock.on('close', () => {
                    this.#connected = false;
                    console.log('[rpc] disconnected');
                });
                sock.on('error', (err) => {
                    sock.destroy();
                    if (attempt < retries && Date.now() < deadline) {
                        setTimeout(tryConnect, retryInterval);
                    } else {
                        reject(err);
                    }
                });
            };

            tryConnect();
        });
    }

    disconnect() {
        this.#vmAddon = null;
        if (this.#socket) {
            this.#socket.destroy();
            this.#socket = null;
        }
        this.#connected = false;
    }

    // ── RPC methods (vm.md §8.3) ──

    /** spawn(id, name, command, args, cwd, env, opts) */
    async spawn(id, name, command, args = [], cwd, env, opts = {}) {
        return this.#call('spawn', {
            id, name, command, args, cwd, env,
            additionalMounts: opts.additionalMounts,
            isResume: opts.isResume,
            allowedDomains: opts.allowedDomains,
            sharedCwdPath: opts.sharedCwdPath,
            oneShot: opts.oneShot,
            mountSkeletonHome: opts.mountSkeletonHome,
        });
    }

    /** kill(id, signal) */
    async kill(id, signal = 'SIGTERM') {
        return this.#call('kill', { id, signal });
    }

    /** writeStdin(id, data) */
    async writeStdin(id, data) {
        return this.#call('writeStdin', { id, data });
    }

    /** isProcessRunning(id) → { running, exitCode } */
    async isProcessRunning(id) {
        return this.#call('isRunning', { id });
    }

    /** installSdk(sdkSubpath, version) */
    async installSdk(sdkSubpath, version) {
        return this.#call('installSdk', { sdkSubpath, version });
    }

    /** addApprovedOauthToken(token) */
    async addApprovedOauthToken(token) {
        return this.#call('addApprovedOauthToken', { token });
    }

    /** readFile(processName, filePath) → { content } */
    async readFile(processName, filePath) {
        return this.#call('readFile', { processName, filePath });
    }

    /** getMemoryInfo() → { totalBytes, freeBytes } */
    async getMemoryInfo() {
        return this.#call('getMemoryInfo', {});
    }

    // ── Internal ──

    #call(method, params) {
        if (!this.#connected) {
            return Promise.reject(new Error('[rpc] not connected'));
        }

        const id = ++this.#requestId;
        const msg = JSON.stringify({ id, method, params });

        // vsock transport: use Swift addon's rpcCall (synchronous request/response)
        if (this.#vmAddon) {
            return this.#vmAddon.rpcCall(msg).then(raw => {
                const resp = JSON.parse(raw);
                if (resp.error) throw new Error(resp.error.message);
                return resp.result;
            });
        }

        // TCP transport: async with pending map
        return new Promise((resolve, reject) => {
            this.#pending.set(id, { resolve, reject });
            this.#socket.write(msg + '\n');
        });
    }

    #onData(chunk) {
        this.#buffer += chunk;
        let newlineIdx;
        while ((newlineIdx = this.#buffer.indexOf('\n')) !== -1) {
            const line = this.#buffer.slice(0, newlineIdx).trim();
            this.#buffer = this.#buffer.slice(newlineIdx + 1);
            if (line) this.#dispatch(line);
        }
    }

    #dispatch(line) {
        let msg;
        try {
            msg = JSON.parse(line);
        } catch {
            console.warn('[rpc] invalid JSON:', line);
            return;
        }

        // Event notification (no id) — forward to callbacks
        if (msg.id == null && msg.method) {
            const p = msg.params ?? {};
            switch (msg.method) {
                case 'onStdout':
                    this.onStdout?.(p.processId, p.data);
                    break;
                case 'onStderr':
                    this.onStderr?.(p.processId, p.data);
                    break;
                case 'onExit':
                    this.onExit?.(p.processId, p.exitCode, p.signal);
                    break;
                case 'onError':
                    this.onError?.(p.processId, p.message, p.fatal);
                    break;
            }
            return;
        }

        // Response — resolve/reject pending promise
        const pending = this.#pending.get(msg.id);
        if (!pending) return;
        this.#pending.delete(msg.id);

        if (msg.error) {
            pending.reject(new Error(msg.error.message));
        } else {
            pending.resolve(msg.result);
        }
    }
}
