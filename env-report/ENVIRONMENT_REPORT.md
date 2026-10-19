# 运行环境实测报告

| 项 | 值 |
|---|---|
| 生成日期 | 2026-10-19（UTC，约 02:30–02:50） |
| 环境标识 | Claude Code 云端会话（claude.ai/code 远程执行环境），hostname `vm`，内核 `6.18.44-fc-v139` |
| 探测时机 | 开机约 1 分钟后开始（`uptime` = `up 1 min`），即一次全新启动 |
| 方法 | 全部结论来自容器内实际命令（命令写在每节"证据"中）；推断项标注 **【推断】**，未实测项标注 **【未验证】** |
| 配套文件 | [`benchmark_results.csv`](./benchmark_results.csv)（性能测试原始数据，每项 3 次 + 中位数） |

---

## 一、机器性能

### 1.1 系统与虚拟化

| 项 | 实测值 | 证据命令 |
|---|---|---|
| 发行版 | Ubuntu 24.04.5 LTS (Noble) | `cat /etc/os-release` |
| 内核 | `6.18.44-fc-v139`，SMP PREEMPT_DYNAMIC，`gcc 15.3.0` 构建，builder `@sandboxing` | `uname -a`、`dmesg` |
| 虚拟化类型 | **Firecracker microVM（KVM 全虚拟化）** | `lscpu` → `Hypervisor vendor: KVM`；内核 cmdline 含 `--firecracker-init`、`rdinit=/process_api` |
| PID 1 | `/process_api`（不是 systemd/init），监听 vsock 端口 2024/5001/5002 | `ps -p 1`、`/proc/cmdline` |
| virtio 设备 | 10 个：6×block、1×net、1×vsock(0x13)、1×balloon(0x05)、1×entropy(0x04) | `/sys/bus/virtio/devices/*/device` |
| `systemd-detect-virt` | 输出 `docker`（**误报**：没有 `/.dockerenv`，cgroup 路径全为 `/`） | `systemd-detect-virt`、`ls /.dockerenv` |
| 内核参数要点 | `nomodule`（禁止加载模块）、`ipv6.disable=1`、`panic=1`、`--block-local-connections` | `/proc/cmdline` |
| 用户 | `uid=0(root)`，seccomp 未启用（`Seccomp: 0`） | `id`、`/proc/self/status` |

> 小插曲：`/etc/hosts` 里有 `127.0.0.1 runsc`（gVisor 运行时的名字），但内核是真 Linux 6.18，`dmesg` 可读，所以**实际是 Firecracker VM 而不是 gVisor**。这一行应是镜像兼容遗留 **【推断】**。

### 1.2 硬件资源

| 项 | 实测值 | 证据命令 |
|---|---|---|
| 架构 | x86_64 | `lscpu` |
| CPU | Intel Xeon @ 2.80GHz（Family 6 Model 85 Stepping 7 → Cascade Lake），**4 vCPU**，每核 1 线程 | `lscpu` |
| 指令集 | AVX2、AVX-512(F/DQ/BW/VL/VNNI)、AES-NI；**无 SHA-NI** | `lscpu` Flags |
| 缓存 | L2 4 MiB、L3 33 MiB | `lscpu` |
| CPU 配额 | 无 cgroup 限制（`cpu.cfs_quota_us = -1`）；4 路并行 sha256 耗时 4.07s，单路 4.26s → **4 核可以线性用满** | cgroup 文件、sha256 实验 |
| 内存 | 总 15 GiB（16,479,424 kB），可用约 15 GiB；cgroup 无限制 | `free -h`、`memory.limit_in_bytes` |
| 内存带宽（单线程 dd） | 约 17.9 GB/s | `dd if=/dev/zero of=/dev/null bs=1M` |
| **Swap** | **无**（0B，`/proc/swaps` 为空；`zram0` 存在但大小 0） | `swapon --show`、`lsblk` |
| 根分区 | `/dev/vda` ext4，设备 252G，已用 9.4G，**可用仅 30G** | `df -hT` |
| ulimit | 打开文件数 20000，最大进程数 64297，core 0 | `ulimit -a` |

> 关于 30G：设备有 252G，但 `df` 只显示 30G 可用。挂载参数是 `resv_strict,resuid=65534,resgid=65534`，ext4 的保留块只给 uid 65534（nobody）用，连 root 也碰不到，这就是会话写入配额的实现方式 **【推断】**。所以写满时报 `No space left`，`df` 的 Used 却不高，属正常现象。

### 1.3 性能画像

- **适合**：中等规模编译（Rust/Go/C++，可 `-j4`）、单元测试、数据处理（15G 内存可装下中型 pandas 数据集）、AVX-512 数值计算、文本和代码批处理。
- **不适合**：超过约 14G 的内存负载。**没有 swap，内存打满会直接 OOM-kill**，不会先变慢再报错。也不适合大于 30G 的数据集，以及需要 GPU 的训练。
- **隐藏坑**：**创建进程很贵**。fork+exec 一次约 1.75–2.2 ms（每秒 448–571 次，详见第五节），比一般物理机慢一个数量级。大量调用外部命令的 shell 循环（`for … do head/sed/awk …`）会被它拖垮，应改成单进程（Python/awk 一次处理）或用 builtin。

---

## 二、网络

### 2.1 出站策略（事实）

| 项 | 实测 |
|---|---|
| 网卡与路由 | 1 块 virtio-net，`eth0` 在 `192.0.2.0/24`（TEST-NET-1 文档保留段），默认网关 `192.0.2.1`（`/proc/net/route`）。没有 `ip`/`ss` 工具 |
| DNS | `/etc/resolv.conf` → 8.8.8.8 / 8.8.4.4，但**解析被过滤**：`github.com`、`pypi.org` 能解析，`example.com`、`google.com` 返回 `Could not resolve host` |
| 显式代理 | `HTTPS_PROXY=http://127.0.0.1:45661`（本地 agent proxy → 远端策略网关，**TLS 在网关重新签发**，需信任 `/root/.ccr/ca-bundle.crt`）。各语言的 CA 环境变量都已预配置（`SSL_CERT_FILE`、`REQUESTS_CA_BUNDLE`、`NODE_EXTRA_CA_CERTS`、`PIP_CERT`、`JAVA_TOOL_OPTIONS` …） |
| NO_PROXY | 包管理源 `pypi.org`、`files.pythonhosted.org`、`registry.npmjs.org`、`index.crates.io`、`proxy.golang.org`、`jsr.io`、`api.anthropic.com` 等**直连、不走代理** |
| 凭据注入 | `GH_TOKEN`/`GITHUB_TOKEN`/`AWS_*`/`CLOUDSDK_AUTH_ACCESS_TOKEN` 的值都是字面量 `proxy-injected`，真实凭据由网关在出站时注入，容器内拿不到 |
| 裸 IP | `https://140.82.112.4/`（github IP）直连失败(000)，`http://1.1.1.1/` 直连得到 403 → 有透明出口过滤，绕过 DNS 也出不去 |
| 结论 | **白名单模式**：双层管控，DNS 过滤加出口网关（CONNECT 403）。即使 `--noproxy '*'`，白名单内的域名仍可达，说明底层还有一层透明出口 |

### 2.2 域名可达性对照表（curl 实测，两组对照：走代理 vs `--noproxy '*'` 直连）

命令：`curl -sS -o /dev/null -m 10 -w '%{http_code} %{time_total}' <URL>`，以及加 `--noproxy '*'` 的版本。

| 类别 | URL | 走代理 | 直连 | 判定 |
|---|---|---|---|---|
| Python | `https://pypi.org/simple/requests/` | 200 (0.12s) | 200 (0.08s) | ✅ 可达 |
| Python | `https://files.pythonhosted.org/` | 404（根路径） | 404 | ✅ 可达（主机通） |
| Node | `https://registry.npmjs.org/express` | 200 | 200 | ✅ |
| Rust | `https://index.crates.io/config.json` | 200 | 200 | ✅ |
| Go | `https://proxy.golang.org/` | 200 | 200 | ✅ |
| Java | `https://repo.maven.apache.org/maven2/` | 200 | 200 | ✅ |
| Ruby | `https://rubygems.org/` | 200 | 200 | ✅ |
| Conda | `https://conda.anaconda.org/` | 302 | 302 | ✅ |
| apt | `https://archive.ubuntu.com/ubuntu/`（HTTP 也是 200；`apt-get update` 4s 拉了 33.8MB） | 200 | 200 | ✅ |
| apt | `https://deb.debian.org/` | **403 (CONNECT)** | DNS 失败 | ❌ 拦截 |
| 代码托管 | `https://github.com/` | 400 `Request path could not be canonicalized`（GitHub 网关） | 200 | ⚠️ 经网关，受限 |
| 代码托管 | `https://api.github.com/repos/ethonchen/examples` | **200** | — | ✅ 范围内仓库 |
| 代码托管 | `https://api.github.com/repos/torvalds/linux` | **403** | — | ❌ 不在会话仓库范围 |
| 代码托管 | `git ls-remote github.com/torvalds/linux` | 成功 | — | ✅ 公开仓库只读可拉 |
| 代码托管 | `https://raw.githubusercontent.com/...` | 200 | 200 | ✅ |
| 代码托管 | `https://gitlab.com/` | 301 | 301 | ✅ |
| 容器镜像 | `https://registry-1.docker.io/v2/`、`https://ghcr.io/v2/` | 401（需认证，正常） | 401 | ✅ 主机可达 |
| 云存储 | `https://storage.googleapis.com/` 400、`https://s3.amazonaws.com/` 307 | ✅ | ✅ | ✅ 主机可达 |
| AI | `https://api.anthropic.com/` | 404（根路径） | 404 | ✅ |
| AI | `https://api.openai.com/v1/models` | **403 (CONNECT)** | DNS 失败 | ❌ |
| AI | `https://huggingface.co/` | **403** | DNS 失败 | ❌ |
| 公网 | `https://www.google.com/` | **403** | DNS 失败 | ❌ |
| 公网 | `https://www.baidu.com/` | **403** | DNS 失败 | ❌ |
| 公网 | `https://example.com/` | **403** | DNS 失败 | ❌ |
| 公网 | `https://en.wikipedia.org/`、`https://stackoverflow.com/`、`https://www.cloudflare.com/` | **403** | DNS 失败 | ❌ |

被拦截时的错误签名：
- 走代理：`CONNECT tunnel failed, response 403`。代理状态接口 `curl $HTTPS_PROXY/__agentproxy/status` 的 `recentRelayFailures` 记为 `connect_rejected: gateway answered 403 to CONNECT (policy denial or upstream failure)`。
- 直连：`curl: (6) Could not resolve host`。

### 2.3 两条网络通道对比（实测）

| 通道 | 实测 | 结论 |
|---|---|---|
| Bash（curl/pip/npm/git） | 见上表，白名单制 | 装依赖、拉代码、调白名单 API |
| Agent 内置 **WebFetch** | `example.com`、`en.wikipedia.org` 均报 `getaddrinfo ENOTFOUND` | **本环境中 WebFetch 和 bash 共用同一套 DNS 与出口限制**，不是独立通道，帮不了你抓白名单外的网页 |
| Agent 内置 **WebSearch** | 查询 "Firecracker microVM" 正常返回结果 | **服务端执行的独立通道**，不受容器出口限制。可以查资料、读搜索摘要，但拿不到可在容器里用的原始文件 |

**画像**：这是"开发够用、上网受限"的网络。几大语言的包管理源、GitHub（按会话仓库授权）、Ubuntu apt、Docker Hub/GHCR、主流云存储都通；通用网站、OpenAI、HuggingFace、Debian 源一律拦截。查资料用 WebSearch。下载模型或数据集要事先确认域名在白名单里，否则只能换源（比如走 GitHub release 或云存储）。

---

## 三、文件系统与目录

### 3.1 挂载点全景（`mount`、`df -hT`、`lsblk`）

| 挂载点 | 设备/类型 | 大小 | 读写 | 安全参数 | 用途 |
|---|---|---|---|---|---|
| `/` | `/dev/vda` ext4 | 252G（可用 30G） | **rw** | `discard,resv_strict,resuid=65534` | 根文件系统，**所有可写数据都在这里** |
| `/opt/claude-code` | `/dev/vdc` ext4 | 302M（92% 满） | **ro** | `nosuid,nodev,norecovery` | Claude Code 本体（`bin/claude` 272MB） |
| `/opt/env-runner` | `/dev/vdd` ext4 | 47M | **ro** | `nosuid,nodev,norecovery` | 环境管理/运行器 |
| `/opt/rclone` | `/dev/vdb` squashfs | 9.6M | **ro** | — | rclone-filestore 二进制（不在 PATH） |
| `/mnt/skills/public` | `/dev/vde` squashfs | 688K | **ro** | — | 公共技能库 |
| `/mnt/skills/examples` | `/dev/vdf` squashfs | 5.8M | **ro** | — | 示例技能库（`*.skill` + 目录） |
| `/dev/shm` | tmpfs | 16G | rw | — | 共享内存（占用的是 RAM） |
| `/sys/fs/cgroup` | tmpfs + cgroup v1/v2 混合 | — | rw | — | cgroup |
| `/run/sandbox-telemetry` | tmpfs 1M | — | rw | `nosuid,nodev,noexec`，uid 64321 | 沙箱遥测 |
| `/mnt/sandboxing/model_tools_env/v1/python` | tmpfs 4K，设备名 `model_tools_unavailable` | — | **ro** | `nosuid,nodev` | 占位，表示模型工具环境在本会话不可用 |

- **本地块设备 vs 远程**：全部是本地 virtio 块设备（vda–vdf），**没有 NFS、FUSE 或任何网络文件系统挂载**。`rclone` 二进制在 `/opt/rclone`，但没有被挂载使用。
- **只读层**：全部挂载在 `/opt` 和 `/mnt/skills` 下（squashfs 或 ro ext4），`/opt` 下的 ext4 带 `nosuid,nodev`。

### 3.2 关键目录

| 目录 | 所在设备 | 角色 |
|---|---|---|
| `/home/user/examples` | vda | **主工作区**（git 仓库，分支 `claude/admiring-newton-5zkrvy`） |
| `/tmp/claude-0/<project>/<session-id>/scratchpad` | vda | **会话草稿区**，按 session id 隔离 |
| `/mnt/user-data/{uploads,working,outputs}` | vda | 上传 / 中间 / 交付目录，**本次均为空**。它们只是根盘上的普通目录，并非独立挂载 |
| `/mnt/attach` | vda | 附件目录（空） |
| `/root/.ccr/` | vda | 代理 CA、README、Java truststore |
| `/root/.claude/` | vda | Claude Code 的状态、会话和插件 |
| `/opt/pw-browsers/` | vda | Playwright 自带的 chromium 1194 / headless shell / ffmpeg |
| `/mnt/skills/*` | vde/vdf | 只读技能和资源库 |

### 3.3 隔离与持久性

- **会话隔离**：草稿区路径含 session id；整个 VM 专属于本会话（开机 1 分钟，进程表里只有本会话的进程）。
- **持久性**：本次是全新启动的 VM，`/tmp` 里只有镜像构建期（Oct 3）的残留文件，没有其他会话的痕迹。按平台说明，容器闲置或会话结束后会被回收，**需要保留的东西必须 commit 并 push**。跨会话重置本身无法在单次会话里实测 **【未验证】**。
- **加固参数**：只读层带 `nosuid,nodev`，遥测目录带 `noexec`；根盘**没有** `nosuid/nodev/noexec`（可执行、可编译）；内核 `nomodule` 禁止加载模块。

**画像**：可写面只有一块盘（vda）。工作区、草稿区、交付目录同盘同性能，放哪里只是组织问题，不影响速度。只读层通过块设备整体下发，改不了也不会被误改。

---

## 四、工具链与限制

### 4.1 已安装（`<tool> --version` 实测）

| 类别 | 工具及版本 |
|---|---|
| Python | Python **3.13.16**（默认），python3.12 也在；pip 24.0、**uv 0.11.32**、Poetry 2.4.3；预装 numpy 2.5.3、pandas 3.0.5 |
| JS | Node **v22.22.0**、npm 10.9.4、pnpm 10.28.0、yarn 1.22.22、**bun 1.4.2** |
| Go / Rust | go **1.24.7**；rustc / cargo **1.97.0** |
| JVM | OpenJDK **21.0.12.1**、Maven 3.9.11、Gradle 8.14.3 |
| C/C++ | gcc/g++ 13.3.0、clang 18.1.3、make 4.3、cmake 3.28.3、ninja 1.11.1 |
| 其他语言 | Ruby 3.3.6 / gem 3.5.22、PHP 8.3.6、Perl 5.38.2 |
| VCS / 云 | git 2.43.0、git-lfs 3.4.1、gh 2.89.0、gcloud 570.0.0、gsutil 5.37、bq |
| 数据库客户端 | psql 16.15、redis-cli 7.0.15（只有客户端） |
| 多媒体 / 文档 | ffmpeg 6.1.1、ImageMagick 6.9.12、pandoc 3.1.3 |
| 浏览器 | Playwright 1.56.1 + `/opt/pw-browsers/chromium-1194`（系统 PATH 里没有 chromium 命令） |
| 调试 | gdb 15.1、valgrind 3.22、strace 6.8 |
| 通用 CLI | curl 8.5.0、wget 1.21.4、jq 1.7、yq、ripgrep 14.1、tmux、vim 9.1、nano 7.2、zip/unzip、nc、sudo、apt 2.8.3 |
| 容器 | docker CLI 29.8.2（**没有 daemon**：`/var/run/docker.sock` 不存在） |

### 4.2 明显缺失

`deno`、`lua`、`R`、`julia`、`dotnet`、`swift`、`kotlin`、`scala`、`sqlite3`(CLI)、`mysql`、`podman`、`kubectl`、`terraform`、`aws` CLI、`az`、`fd`、`7z`、`rsync`、`fio`、`iperf3`、`sysbench`、`htop`。网络诊断三件套 **`ip`/`ss`/`netstat`/`dig`/`nslookup`/`ping`/`traceroute` 全部没有**。`apt-get update` 可用（archive.ubuntu.com 在白名单），缺什么大多能 `apt-get install` 补上。

### 4.3 踩坑点与硬限制汇总

| # | 坑 / 限制 | 实测依据 | 对策 |
|---|---|---|---|
| 1 | **无 swap，内存上限约 15G** | `free -h` | 大任务分块处理；内存打满直接 OOM，没有缓冲 |
| 2 | **磁盘可写仅约 30G** | `df` | 及时清理构建产物和缓存（`~/.cache`、`target/`、`node_modules`） |
| 3 | **进程创建慢**（fork+exec 约 2ms） | 第五节进程测试 | 避免 shell 循环里逐个调外部命令 |
| 4 | **PEP 668**：默认 `python3`(3.13) 的 pip **不受限**，可直接装；`python3.12 -m pip` 报 `externally-managed-environment` | `pip3 install --dry-run humanize` 成功；3.12 报错 | 用默认 python3 或 uv/venv；必须用 3.12 时加 `--break-system-packages` 或建 venv |
| 5 | **网络白名单** | 第二节 | 不要重试 403；换白名单源 |
| 6 | **TLS 被网关重签** | `/root/.ccr/README.md` | 自带 CA 配置的工具要指向 `/root/.ccr/ca-bundle.crt`；**不要关闭证书校验** |
| 7 | 代理只支持 HTTPS CONNECT | README | 不要设 `HTTP_PROXY`（会得到 405）；Node 原生 fetch 需要 `NODE_USE_ENV_PROXY=1` |
| 8 | GitHub 按会话授权仓库访问 | api.github.com 对范围外仓库返回 403 | 范围外仓库只能匿名 `git clone` 公开仓库 |
| 9 | 只读目录 | `mount` 显示 ro | 要改技能或工具，先复制到可写目录 |
| 10 | 没有 Docker daemon | `docker ps` 失败 | 跑不了容器化测试 |
| 11 | 文件系统随会话回收 | 平台说明 + 全新启动 | 产出要 commit/push |
| 12 | 无 IPv6、不能加载内核模块 | cmdline `ipv6.disable=1 nomodule` | — |

---

## 五、存储读写性能测试

### 5.1 方法

- 工具：`dd` + `date +%s.%N` 计时（脚本 `bench.sh`）。每项跑 3 次取中位数；每次测试前 `sync; echo 3 > /proc/sys/vm/drop_caches`（**有权限**，写入成功）。小文件补充测试用 bash builtin 和 Python 做对照。
- 被测对象：
  - **vda_ext4**：根盘（工作区、草稿区、`/mnt/user-data/outputs` 都在这里）
  - **tmpfs_shm**：`/dev/shm`，内存盘对照组
  - **只读盘**：`/dev/vdc`（ext4，读 272MB 文件）、`/dev/vdf`（squashfs，读 2.6MB 文件）
- 说明：环境中**不存在远程、FUSE 或独立输出挂载**（`/mnt/user-data/outputs` 也在 vda），因此"本地 vs 远程"对比改为"磁盘 vs 内存盘 vs 只读层"。

### 5.2 a. 顺序吞吐：小数据量 vs 打穿缓存

| 测试 | vda ext4 | tmpfs | 说明 |
|---|---|---|---|
| 写 64MB，不 sync | **1472 MB/s** | 1115 MB/s | 只写进 page cache，是**缓存假象** |
| 写 64MB + fdatasync | 518 MB/s | 1059 MB/s | 强制落盘后 ext4 的真实速度 |
| 写 2GB + fdatasync | **436 MB/s** | 493 MB/s | 持续落盘吞吐，可视为 vda 的真实上限 |
| 写 4GB，不 sync | 450 MB/s | 804 MB/s | 超过脏页阈值（`dirty_ratio=20%` ≈ 3GB）后被强制回写限速，和 fdatasync 结果收敛 |

### 5.3 b. 冷读 vs 热读

| 测试 | vda ext4 (1GB) | tmpfs (1GB) | ro vdc ext4 (272MB) | ro vdf squashfs (2.6MB) |
|---|---|---|---|---|
| 冷读（drop_caches 后） | **1839 MB/s** | 4106 MB/s | 1304 MB/s | 147 MB/s |
| 热读（page cache 命中） | **5276 MB/s** | 4419 MB/s | 4246 MB/s | 331 MB/s |
| 热/冷 倍数 | 2.9× | 1.1× | 3.3× | 2.3× |

### 5.4 c. 小块 / 小文件 / 元数据

| 测试 | vda ext4 | tmpfs | 说明 |
|---|---|---|---|
| 4K 写，缓冲（25600 次） | 164,096 IOPS | 315,841 IOPS | 缓冲写，基本是内存速度 |
| 4K 写，`oflag=dsync` | **2,292 IOPS** | 169,734 IOPS | 每次写都落盘 |
| **单次 fsync 延迟（4K dsync）** | **≈436 µs** | ≈5.9 µs | ext4 日志加 virtio 往返；tmpfs 的 fsync 是空操作 |
| 小文件创建，每文件 fork 一次 `head` | 411 files/s | 433 files/s | ⚠️ 两者几乎一样，**瓶颈是进程创建，不是文件系统** |
| 小文件创建，bash builtin（20000 个，无 fork） | 2,589 files/s（首轮 10,912） | 17,025 files/s | 剥离 fork 后的真实元数据速度 |
| 小文件创建，每个都 fsync（Python，2000 个） | 1,129 files/s | 53,033 files/s | 持久化小文件的真实上限 |
| 小文件删除（5000 个） | 4,318 files/s | 150,990 files/s | — |

进程创建对照（同一次测试的上下文）：

| 测试 | 速率 | 单次成本 |
|---|---|---|
| bash 循环 `/bin/true` | 448 /s | ≈2.2 ms |
| C 语言纯 `fork()` | 3,620 /s | ≈0.28 ms |
| C 语言 `fork()+exec(/bin/true)` | 571 /s | ≈1.75 ms → **exec 占约 85%** |
| Python `subprocess.run` | 590 /s | ≈1.7 ms |

### 5.5 差异成因解读

1. **短测虚高（缓存假象）**：64MB 不 sync 测到 1472 MB/s，是只写进 page cache 的速度。加上 fdatasync 或把数据量放大到超过脏页阈值后，都收敛到约 440–520 MB/s，这才是 vda 的真实写入能力。本环境**没有 FUSE write-back 缓存**，虚高只来自内核 page cache。
2. **热读飙高**：冷读 1.8 GB/s，热读 5.3 GB/s（2.9 倍），差值就是 page cache 命中的收益。内存有 15G，常用的工作集基本都能常驻缓存。
3. **tmpfs 并非总是更快**：2GB 写 tmpfs 只有约 500 MB/s，比 64MB 慢一倍。对照实验中同样写 2GB，三次分别为 177 / 1685 / 563 MB/s，波动极大。原因是 Firecracker 的客户机内存由宿主**按需分配**（首次触碰页面会触发 EPT 缺页，virtio-balloon 也会回收），第一次占用新内存很慢 **【推断，依据：波动规律 + balloon 设备存在】**。
4. **fsync 贵约 75 倍**：vda 单次 fsync 约 436µs（tmpfs 5.9µs），每次都要穿过 ext4 日志、virtio-blk 和宿主存储。每写一点就 fsync 的程序（SQLite 默认模式、某些包管理器）在这里会慢。
5. **小文件慢在进程，不在磁盘**：每建一个文件 fork 一次 `head`，ext4 和 tmpfs 都卡在约 420/s；换成 builtin 后 ext4 升到 2.6k–11k/s，tmpfs 升到 17k/s。bash 首轮 10.9k、后续 2.5k 的差异，可能与 ext4 目录项/inode 分配、`discard` 回收有关 **【推断】**。
6. **squashfs 小文件冷读慢**（147 MB/s）：读取要解压，而且文件太小，固定开销占比高。

### 5.6 实践建议

| 场景 | 建议 |
|---|---|
| 草稿 / 迭代 | 放**会话草稿区**或仓库工作区（都在 vda，同样快）。高频生成、读完就丢的中间文件，体积不大时可以放 `/dev/shm`（但占内存，而且第一次分配慢） |
| 成品定稿 | 所有可写位置都在同一块 vda 上，**位置不影响性能，影响的是能不能保留**：成品必须 `git commit && git push`，或交给平台的 outputs/Artifact 机制。VM 回收后本地文件不保证留存 |
| 写大文件 | 按约 450 MB/s 估算持续写入；不要用短测数字做容量规划 |
| 大量小文件 | 用单进程（Python/Node/`tar`）批量写，不要在 shell 循环里调外部命令 |
| 数据库测试 | SQLite/Postgres 的数据目录可以放 tmpfs 来提速（fsync 近乎为零），但数据不持久 |
| 磁盘空间 | 只有 30G：`cargo`/`npm`/`pip` 缓存和 Docker 层（虽然没有 daemon）要注意清理 |

---

## 六、整体安全与设计小结

1. **硬件级隔离加一次性实例**：每个会话一台专属 Firecracker microVM（KVM），PID 1 是自研的 `process_api`，通过 vsock 接受控制，不跑 systemd，`nomodule` 禁止加载内核模块。容器内给 root，代价不大，因为边界在 VM 层，不在用户权限层。VM 用完即回收，没有跨会话的残留状态。
2. **白名单网络加凭据外置**：DNS 过滤、CONNECT 网关 403 和透明出口过滤三层叠加，只放行开发必需的域名。TLS 在网关重签，可以审计流量。GitHub、GCP、AWS 的凭据只以 `proxy-injected` 占位符出现，**真实 token 不进 VM**，即使 VM 被攻破也偷不到。GitHub 访问还按会话授权仓库收窄。
3. **读写分离**：工具链（Claude Code、env-runner、rclone）和技能库以**只读块设备**（squashfs / ro ext4 + `nosuid,nodev`）下发，所有可写数据集中在一块 ext4 上，并用 ext4 保留块机制限额到约 30G。
4. **取舍点评**：这套设计在"能干活"一侧给得相当大方：root、4 核 15G、主流语言工具链齐全、各大包管理源和 apt 可用、写盘约 450 MB/s。在"够安全"一侧则把风险收在 **VM 边界、网络出口和凭据**这三处，而不是用 seccomp 或降权去限制容器内的行为。代价是：通用上网受限（要靠服务端 WebSearch 补），没有 Docker daemon，没有 swap，磁盘只有 30G，进程创建开销偏高，而且一切都是一次性的，产出必须主动 push。对"在仓库里写代码、跑测试、提 PR"这类工作非常合适；对"爬网页、下大模型、跑容器编排"不合适。

---

### 配套文件

- `benchmark_results.csv`：第五节全部原始数据（`target,device,test,metric,unit,run1,run2,run3,median`），包含对照实验（bash builtin 小文件、Python fsync、tmpfs 首次/再次触碰、进程创建、CPU 并行、内存带宽）。
- `bench.sh`：可复现的基准测试脚本。
