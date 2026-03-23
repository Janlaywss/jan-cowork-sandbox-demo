# JanworkVM

用 Swift + Rust 从零实现一个 macOS 上的 Linux 沙箱虚拟机——复刻 Claude Desktop (Cowork) 的核心沙箱架构。

```
┌── Host (macOS) ─────────────────┐     ┌── Guest VM (Linux) ─────────┐
│                                  │     │                             │
│  Node.js (demo.mjs)              │     │  Ubuntu 22.04               │
│  ├─ Swift N-API addon            │     │  ├─ UEFI → GRUB → kernel   │
│  │   Virtualization.framework    │     │  ├─ systemd                 │
│  │   createVM / startVM / vsock  │     │  └─ janworkd (Rust daemon)  │
│  └─ JSON-RPC client             │────→│     vsock:9100               │
│                                  │vsock│     spawn / kill / readFile │
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


## 完整 VM 模式

真正启动一台 Linux 虚拟机，通过 vsock 通信。

### 前置依赖

```bash
# Rust 交叉编译工具链
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source ~/.cargo/env
rustup target add aarch64-unknown-linux-musl

# macOS 工具
brew install e2fsprogs qemu
```

### 构建 + 运行

```bash
cd vm

# 1. 编译 Swift addon + 签名（赋予虚拟化 entitlement）
./build.sh && ./sign.sh

# 2. 交叉编译 Rust daemon（macOS 上编译出 Linux aarch64 静态二进制）
cd daemon && ./build-image.sh --build-only && cd ..

# 3. 下载 Ubuntu cloud image → 转为 raw 格式 → 扩容 10GB
./get-base-image.sh

# 4. 注入 daemon + systemd 服务 + 网络配置到镜像中
./customize-rootfs.sh rootfs.img

# 5. 启动
mkdir -p bundle && cp rootfs.img bundle/
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
  → v99999222
spawn "echo" process...
  → running=false exitCode=0
readFile /etc/hosts...
  → "127.0.0.1 localhost | ..."

[Phase 4] Shutdown
VM stopped

=== Demo Complete ===
```

## 项目结构

```
vm/
├── demo.mjs                    # Demo 入口，驱动完整流程
├── rpc-client.mjs              # JSON-RPC 客户端（vsock / TCP 双通道）
│
├── Sources/                    # Swift N-API addon（宿主机侧）
│   ├── JanworkVMManager.swift  #   VM 管理：3-disk、UEFI boot、vsock、balloon
│   ├── NAPIModule.swift        #   N-API 方法注册（vm.createVM / startVM / ...）
│   └── NAPIHelpers.swift       #   N-API 类型转换工具
│
├── daemon/                     # Rust daemon（Guest 侧）
│   └── src/
│       ├── main.rs             #   入口：vsock 监听（Linux）/ TCP 监听（macOS 测试）
│       ├── rpc.rs              #   JSON-RPC 分发（8 个方法）
│       ├── process.rs          #   进程管理：spawn / kill / stdin / stdout 转发
│       └── network.rs          #   域名白名单过滤
│
├── get-base-image.sh           # 下载 Ubuntu cloud image + QCOW2→raw 转换
├── customize-rootfs.sh         # 注入 daemon 到镜像（debugfs 写入 ext4）
├── build.sh                    # Swift 编译
├── sign.sh                     # 代码签名（虚拟化 entitlement）
└── js/index.js                 # SwiftAddon EventEmitter 封装
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

支持的 JSON-RPC 方法：

| 方法 | 说明 |
|------|------|
| `spawn` | 创建进程（支持 cwd、env、域名白名单） |
| `kill` | 发信号终止进程 |
| `writeStdin` | 向进程 stdin 写数据 |
| `isRunning` | 查询进程状态和退出码 |
| `readFile` | 读取 Guest 内文件 |
| `getMemoryInfo` | 读取 `/proc/meminfo` 返回内存信息 |
| `installSdk` | SDK 安装（demo 返回固定版本） |
| `addApprovedOauthToken` | OAuth token 注入（demo 仅打印） |

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

## 运行模式

| 模式 | 命令 | 需要镜像 | 说明 |
|------|------|---------|------|
| **跳过 VM** | `node demo.mjs --skip-vm` | 否 | macOS 上直接跑 daemon（TCP），最快验证 RPC |
| **完整 VM** | `node demo.mjs` | 是 | 真实虚拟机 + vsock 通信 |
| **TCP 调试** | `node demo.mjs --tcp` | 是 | 启动 VM 但 daemon 走 TCP（方便抓包） |

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
