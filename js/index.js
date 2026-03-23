/**
 * js/index.js — JS wrapper for the JanworkVM native addon.
 *
 * Matches the production @ant/claude-swift SwiftAddon pattern (vm.md §5.1):
 *   - EventEmitter-based event forwarding from Swift
 *   - Grouped API namespaces (vm, events, ...)
 *   - isRunning/isGuestConnected wrapped as async for cross-platform compat
 */
const EventEmitter = require("events");

class SwiftAddon extends EventEmitter {
    constructor() {
        super();

        if (process.platform !== "darwin") {
            throw new Error("This module is only available on macOS");
        }

        const native = require("../build/smolvm.node");

        // Wrap vm namespace: isRunning/isGuestConnected always return Promise<boolean>
        // to match the Windows vmClient contract (vm.md §5.1).
        const rawVm = native.vm;
        this.vm = {
            ...rawVm,
            isRunning: async (...args) => rawVm.isRunning(...args),
            isGuestConnected: async (...args) => rawVm.isGuestConnected(...args),
        };
    }
}

if (process.platform === "darwin") {
    module.exports = new SwiftAddon();
} else {
    module.exports = {};
}
