# JanworkVM

用 Swift + Rust 从零实现一个 macOS 上的 Linux 沙箱虚拟机——复刻 Claude Desktop (Cowork) 的核心沙箱架构。

```
┌── Host (macOS) ─────────────────┐     ┌── Guest VM (Linux) ─────────┐
│                                  │     │                             │
│  Node.js (demo.mjs)              │     │  Ubuntu 22.04               │
│  ├─ Swift N-API addon            │     │  ├─ UEFI → GRUB → kernel   │
│  │   Virtualization.framework    │     │  ├─ systemd                 │
│  └─ JSON-RPC client             │────→│  └─ janworkd (Rust daemon)  │
│                                  │vsock│     vsock:9100               │
└──────────────────────────────────┘     └─────────────────────────────┘
```

## 这是什么

这个项目是对 Claude Desktop 沙箱机制的独立复现。Claude Desktop 在用户电脑上启动一台隐形的 Linux 虚拟机，AI agent 的代码全部在虚拟机内执行，从而实现硬件级隔离。

我们用 ~2000 行代码重新实现了这套机制的核心链路：

| 层级             | 本项目  |
|----------------|--------|
| JS → Native 桥接 | `build/smolvm.node` (Swift N-API addon) |
| VM 管理          |`JanworkVMManager` (Swift, ~570 行) |
| 虚拟化            | Apple Virtualization.framework |
| Host↔Guest 通信  | vsock + JSON-RPC |
| Guest 守护进程     | `janworkd` (Rust, 715KB) |
| 系统镜像           | 标准 Ubuntu cloud image + 注入 |

## 快速开始

### 前置依赖（一次性）

```bash
# Rust 工具链（用于交叉编译 Guest 端 daemon）
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
rustup target add aarch64-unknown-linux-musl

# macOS 工具（e2fsprogs 用于写入 ext4 分区，qemu 用于镜像格式转换）
brew install e2fsprogs qemu
```

### 构建

```bash
cd vm

# Swift addon（编译 + 签名，签名赋予虚拟化 entitlement）
./build.sh && ./sign.sh

# Rust daemon（交叉编译为 Linux aarch64 静态二进制）
cd daemon && ./build-image.sh --build-only && cd ..
```

### 不启动 VM 也能玩（最快验证）

如果只想验证 RPC 协议，不需要镜像，不需要 VM：

```bash
node demo.mjs --skip-vm
```

这会在 macOS 上直接启动 Rust daemon（TCP 模式），然后通过 JSON-RPC 和它交互。几秒钟就能看到结果。

手动测试更直接：

```bash
# 终端 1：启动 daemon
cd daemon && cargo run

# 终端 2：用 nc 发 JSON-RPC
echo '{"id":1,"method":"spawn","params":{"id":"s1","name":"test","command":"echo","args":["hello"]}}' | nc localhost 9100
echo '{"id":2,"method":"readFile","params":{"filePath":"/etc/hosts"}}' | nc localhost 9100
```

## 完整 VM 模式

真正启动一台 Linux 虚拟机，通过 vsock 与 Guest 通信。这需要一个 UEFI 可启动的 rootfs.img。

### 获取 Base Image

Apple 的 `Virtualization.framework` 使用 `VZEFIBootLoader`，要求磁盘是 GPT 分区、带有 EFI System Partition。好消息是 Ubuntu 22.04 的 arm64 cloud image 自带 GPT + EFI 分区（partition 15），可以直接用于 UEFI 启动。

运行脚本自动下载并转换为 raw 格式：

```bash
./get-base-image.sh
```

它会做三件事：
1. 从 `cloud-images.ubuntu.com` 下载 Ubuntu 22.04 cloud image（~700MB）
2. 将 QCOW2 格式转为 raw 格式
3. 扩容到 10GB（sparse，不占实际磁盘空间）

也可以手动操作：

```bash
curl -LO https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-arm64.img
brew install qemu
qemu-img convert -f qcow2 -O raw ubuntu-22.04-server-cloudimg-arm64.img rootfs.img
qemu-img resize -f raw rootfs.img 10G
```

### 定制 rootfs

拿到 base image 后，注入我们的 Rust daemon：

```bash
# 注入 janworkd daemon + systemd 服务 + vsock 模块配置
./customize-rootfs.sh rootfs.img

# 放入 bundle 目录
mkdir -p bundle && cp rootfs.img bundle/
```

`customize-rootfs.sh` 用 `e2fsprogs` 的 `debugfs` 在 macOS 上直接写入 ext4 分区（不需要 mount、不需要 Linux 环境），写入内容：

| 步骤 | 写入内容 | Guest 内路径 |
|------|---------|-------------|
| 1 | QCOW2 → raw 转换 + 扩容 10G | — |
| 2 | ext4 文件系统检查 (e2fsck) | — |
| 3 | janworkd.service (systemd) | `/etc/systemd/system/` |
| 4 | sdk-daemon (Rust 二进制) | `/usr/local/bin/sdk-daemon` |
| 5 | sandbox-helper (stub) | `/usr/local/bin/sandbox-helper` |
| 6 | hostname = claude | `/etc/hostname` |
| 7 | vsock 内核模块自动加载 | `/etc/modules-load.d/vsock.conf` |
| 8 | 禁用 cloud-init（加速首次启动） | `/etc/cloud/cloud-init.disabled` |
| 9 | srt-settings.json | `/smol/bin/srt-settings.json` |

### 运行完整 demo

```bash
node demo.mjs
```

### 运行效果

```
=== JanworkVM Integrated Demo ===
Mode: VM + vsock (full)

[Phase 1] VM Setup
Host: 64GB RAM, tier max=8GB
Starting VM (8GB, 3 disks, UEFI boot)...
  VM state: running

[Phase 2] Connect to Guest Daemon
[janwork] starting janworkd (Rust daemon)
[janwork] listening on vsock port 9100
[janwork] vsock client connected

[Phase 3] RPC Calls
installSdk...
  → v99999222              ← 确认是我们的 Rust daemon 在响应
spawn "echo" process...
  → running=false exitCode=0
readFile /etc/hosts...
  → "127.0.0.1 localhost | ..."

[Phase 4] Shutdown
VM stopped

=== Demo Complete ===
```

## 一步到位

如果你只想最快跑通完整 VM 模式：

```bash
# 安装依赖
brew install e2fsprogs qemu
rustup target add aarch64-unknown-linux-musl

# 构建
cd vm
./build.sh && ./sign.sh
cd daemon && ./build-image.sh --build-only && cd ..

# 获取 + 定制 rootfs
./get-base-image.sh
./customize-rootfs.sh rootfs.img
mkdir -p bundle && cp rootfs.img bundle/

# 运行
node demo.mjs
```

## 运行模式

| 模式 | 命令 | 需要镜像 | 说明 |
|------|------|---------|------|
| **跳过 VM** | `node demo.mjs --skip-vm` | 否 | macOS 上直接跑 daemon（TCP），最快验证 RPC |
| **完整 VM** | `node demo.mjs` | 是 | 真实虚拟机 + vsock 通信 |
| **TCP 调试** | `node demo.mjs --tcp` | 是 | 启动 VM 但 daemon 走 TCP（方便抓包） |

## 项目结构

```
vm/
├── demo.mjs                 # Demo 入口，驱动完整流程
├── rpc-client.mjs           # JSON-RPC 客户端 (vsock/TCP 双通道)
├── get-base-image.sh        # 获取 UEFI 可启动的 base image
├── customize-rootfs.sh      # rootfs 定制脚本
├── js/index.js              # SwiftAddon EventEmitter 封装
├── build.sh                 # Swift addon 构建脚本
├── sign.sh                  # 代码签名 (虚拟化 entitlement)
├── entitlements.plist       # com.apple.security.virtualization
├── Package.swift            # Swift 包清单
├── Sources/
│   ├── JanworkVMManager.swift  # VM 管理器 (3-disk, vsock, balloon)
│   ├── NAPIModule.swift        # N-API 注册 (vm namespace)
│   ├── NAPIHelpers.swift       # N-API 工具函数
│   ├── napi_bridge.h
│   └── module.modulemap
└── daemon/
    ├── Cargo.toml
    ├── build-image.sh       # 交叉编译 + exFAT 打包
    ├── srt-settings.json    # 网络域名白名单
    ├── .cargo/config.toml   # 交叉编译配置
    └── src/
        ├── main.rs          # 入口, vsock/TCP 监听
        ├── rpc.rs           # JSON-RPC 分发
        ├── process.rs       # 进程管理 (spawn/kill/stdin)
        └── network.rs       # 域名过滤
```

## 工作原理

### 宿主机侧（Swift）

`JanworkVMManager` 用 Apple Virtualization.framework 组装一台虚拟机：

- **UEFI 启动**：`VZEFIBootLoader` + `efivars.fd`，引导链为 shim → GRUB → Linux kernel → systemd
- **三块磁盘**：rootfs（系统盘）、sessiondata（会话数据）、smol-bin（工具盘，只读）
- **vsock**：`VZVirtioSocketDevice`——不走网络栈的 Host↔Guest 通信通道
- **内存 Balloon**：`VZVirtioTraditionalMemoryBalloonDevice` + `DispatchSource.makeMemoryPressureSource` 监听 macOS 内存压力，动态伸缩 VM 内存
- **自定义 DispatchQueue**：绕过 `@MainActor` 限制（Node.js 不驱动 CFRunLoop）

整个 VM 配置的核心就是一段 Swift：

```swift
let config = VZVirtualMachineConfiguration()
config.cpuCount = 2
config.memorySize = UInt64(memoryGB) * 1024 * 1024 * 1024
config.bootLoader = VZEFIBootLoader()                          // UEFI
config.storageDevices = [rootfs, sessiondata, smolBin]          // 3 disks
config.socketDevices = [VZVirtioSocketDeviceConfiguration()]    // vsock
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
config.networkDevices = [VZVirtioNetworkDeviceConfiguration()]  // NAT
try config.validate()
let vm = VZVirtualMachine(configuration: config, queue: customQueue)
vm.start(completionHandler: ...)
```

### Guest 侧（Rust）

`janworkd` 是一个 715KB 的静态编译二进制，开机通过 systemd 自启动，监听 vsock 端口 9100。

支持的 JSON-RPC 方法（对应 vm.md §8.3）：

| 方法 | 参数 | 说明 |
|------|------|------|
| `spawn` | id, name, command, args, cwd, env | 创建进程（支持 cwd、env、域名白名单） |
| `kill` | id, signal | 发送信号终止进程 |
| `writeStdin` | id, data | 向进程 stdin 写数据 |
| `isRunning` | id | 查询进程状态和退出码 |
| `readFile` | filePath | 读取 Guest 内文件 |
| `getMemoryInfo` | — | Guest 内存信息（Linux 上读 /proc/meminfo） |
| `installSdk` | sdkSubpath, version | 安装 SDK（demo 返回固定版本号） |
| `addApprovedOauthToken` | token | 注入 OAuth token（demo 仅打印） |

通信协议是换行分隔的 JSON-RPC：

```
→ {"id":1,"method":"spawn","params":{"id":"s1","command":"echo","args":["hello"]}}
← {"id":1,"result":{"ok":true}}
← {"method":"onStdout","params":{"processId":"s1","data":"hello\n"}}
```

### 镜像制作

`customize-rootfs.sh` 用 `e2fsprogs` 的 `debugfs` 在 macOS 上直接写入 ext4 分区（不需要 mount、不需要 Linux 环境）：

```
Ubuntu cloud image (QCOW2, ~700MB)
  → qemu-img convert → raw (10GB sparse)
    → debugfs 写入:
      /usr/local/bin/sdk-daemon        ← Rust daemon 二进制
      /etc/systemd/system/janworkd.service  ← 开机自启
      /etc/modules-load.d/vsock.conf   ← 加载 vsock 内核模块
      /smol/bin/srt-settings.json      ← 网络域名白名单
```

## 系统要求

- macOS 13+ (Ventura 或更新)
- Apple Silicon 或 Intel Mac（需支持虚拟化）
- Node.js 18+
- Xcode Command Line Tools（`swiftc`）

## 相关文档

- [vm.md](../vm.md) — Cowork VM 虚拟化实现的完整逆向分析
- [security.md](../security.md) — Cowork 六层纵深防御安全模型
- [infra.md](../infra.md) — Claude Desktop 应用架构分析
- [docs.md](../docs.md) — 《Claude Cowork 沙箱技术分析》文章

## License

MIT
