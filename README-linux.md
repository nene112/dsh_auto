# DeepSeek Harness — 服务器（Linux）一键部署包

针对 `@deepseek-ai/dsh` **0.2.1-rc.3** 校准。`start.sh` 是 `start.ps1` 的 Linux 对等版。

## 包内容

| 文件 | 用途 |
| --- | --- |
| `start.sh` | Linux 一键脚本：环境检查 → 装依赖 → 打补丁 → 配 tailnet → systemd 启动 → 自验证 |
| `start.ps1` | Windows 版（同一套补丁逻辑，留着备用） |
| `package.json` / `package-lock.json` | 依赖清单，`npm ci` 用；已锁定 `@deepseek-ai/dsh@0.2.1-rc.3` |
| `README-linux.md` | 本文件 |

包里**不含 `node_modules`**：脚本会在服务器上 `npm ci`（Linux 原生模块必须在目标机编译）。

## 前提

- Linux（x86_64 或 arm64），有 systemd（要用开机自启的话）
- 有 `python3` 或 `perl`（用于打补丁；脚本会探测哪个可用）
- 装了 Tailscale 并已登录（没有也行，加 `--no-tailscale` 则只监听本机）
- 想用 systemd / 装 Node 需要 root
- **浏览器要求（0.2.x 强制）**：Firefox ≥ **121** / Chrome ≥ **119** / Safari ≥ **17.4**。
  更旧的浏览器会**白屏**，控制台报 `Promise.withResolvers is not a function` 或
  `SyntaxError: expected property name, got '{'`（后者是看不懂 `class { static {} }`，Firefox 93+ 才有）。
  0.1.x 没有这些新语法，所以旧浏览器能跑老版。

## 参数

| 参数 | 说明 |
| --- | --- |
| `--port N` | dsh 监听端口，默认 `3080` |
| `--ts-port N` | tailscale serve 的 HTTPS 端口，默认 `443` |
| `--no-tailscale` | 只监听本机，不做 tailnet 入口 |
| `--install-service` | 装 systemd 单元并开机自启 |
| `--uninstall-service` | 卸掉 systemd 单元（tailnet 入口不动） |
| `--user NAME` | 服务以哪个用户运行，默认 `$SUDO_USER` 或 `root` |
| `--service-name NAME` | systemd 单元名，默认 `dsh` |
| `--node-prefix DIR` | 私有 Node 装哪，默认 `/opt/dsh-auto/node` |
| `--check-only` | 只出环境报告，不做任何改动 |
| `--selftest` | 只验脚本自身逻辑（版本比较、打补丁、信任行），零副作用 |
| `--diagnose` | **只读诊断**：页面空白时跑这个，直接给结论（见下） |
| `--force` | 明知有冲突仍继续（见下） |
| `--clone` | 不在仓库目录时先 `git clone` |

## 系统足迹：这个脚本会碰服务器上的什么

| 位置 | 什么时候 | 会覆盖别人的东西吗 |
| --- | --- | --- |
| `<仓库目录>/node_modules` | 总是 | 不会，只在这个目录里 |
| `<node-prefix>`（默认 `/opt/dsh-auto/node`） | **仅当**主机没有可用的 Node 时才装 | 不会。**故意不装进 `/usr/local`**——那样会顶掉全机的 `node`/`npm` 并遮蔽发行版的 Node |
| `<服务用户 home>/.dsh/profiles/web/cordis.patch.yml` | 有 tailnet 入口时 | 只**追加**一行 `connection`；已存在则跳过 |
| `/etc/systemd/system/<服务名>.service` | 仅 `--install-service` | 文件已存在且不是本脚本写的 → **拒绝**，除非 `--force` |
| `tailscale serve --https=<端口>` 映射 | 有 tailnet 入口时 | 该端口已被别的服务占用 → **拒绝**，除非 `--force` |

不会做的事：**不安装任何全局 npm 包、不添加防火墙规则、不动其他服务、不杀任何进程、不使用 Funnel**。

### 预检（Preflight）

跑任何有副作用的步骤之前先检查三件事，冲突就停下来告诉你：

1. dsh 端口被别的进程占用 → 拒绝，提示换 `--port N`
2. tailscale HTTPS 端口已在服务别的东西 → 拒绝，提示换 `--ts-port N`
3. 同名 systemd 单元存在但不是本脚本写的 → 拒绝，提示 `--service-name` 或 `--force`

（若端口是被本脚本自己装的单元占用，则识别为"重装"，正常继续。）

## 三步上手

```bash
chmod +x start.sh                 # 解包后补执行位（或直接用 bash ./start.sh）

./start.sh --selftest             # ① 零副作用：验脚本自身逻辑（版本比较、打补丁引擎）
sudo ./start.sh --check-only      # ② 只出环境报告，不装任何东西
sudo ./start.sh --install-service # ③ 正式装机 + 开机自启
```

装完脚本自己会跑一遍验证：`401`（0.2.x 鉴权生效）→ 带 token 换 cookie（`303`）→ 页面 `200` → `WS /api/remote.mux` `101`。

## 取访问地址

```bash
journalctl -u dsh --no-pager | grep 'dsh web:'
# -> dsh web: http://127.0.0.1:3080/?token=XXXXXXXX
```

首次访问必须带 token，之后 30 天内靠 cookie：

```
https://<你的节点名>.<tailnet>.ts.net/?token=XXXXXXXX
```

- token **每次启动都会重新生成**，但已发出的 cookie 不受影响（重启后仍免 token）
- 本机访问同样需要 token（0.2.x 对所有请求都鉴权）

## 常用命令

```bash
systemctl status dsh            # 状态
systemctl restart dsh           # 重启（token 会变，cookie 不变）
journalctl -u dsh -f            # 实时日志（找 token 看 'dsh web:'）
sudo ./start.sh --uninstall-service          # 卸服务
tailscale serve --https=443 off              # 撤掉 tailnet 入口
```

## 必须自己补的两件事

1. **模型配置与密钥**：服务器是全新的 `~/.dsh`，没有你本地的 provider 配置。两条路：
   - 推荐：登录 GUI → 设置 → 添加 provider（`baseURL`、模型 id、API key）。非 loopback 下设置页能用，正是脚本打的补丁在起作用。
   - 或者：把本地 `~/.dsh/.credentials.yaml` 复制到服务器同名路径，并把 `llm-pi-ai`、`agent-default-model` 两段配置贴进服务器的 `~/.dsh/profiles/web/cordis.patch.yml`。
2. **工作区**：agent 只能操作**服务器上的文件**，看不到你本机（或 Mac）的项目目录。

## 安全边界

- dsh 只绑 `127.0.0.1`，唯一入口是 `tailscale serve`（**tailnet only，脚本从不使用 Funnel**）
- 0.2.x 对所有请求鉴权；token + 30 天 cookie
- 门禁范围 = 整个 tailnet。公网服务器上的 tailnet 成员、以及带 tag 的设备（如 app-connector / exit node）都能访问这个 GUI
- **不要**给 dsh 端口开公网防火墙规则；脚本也不会开

## 页面空白？先跑这一条

```bash
sudo ./start.sh --diagnose
```

它只读不改动，会跑完探针后**直接给结论**。空白的成因只有两种，本版已能自动区分：

| 探针结果 | 含义 | 页面上看到 |
| --- | --- | --- |
| `tailnet /api, no cookie : 403` | **信任围栏拒绝**：页面 HTML 能加载，但每个 API 调用都 403 | **真·空白页** |
| `tailnet /api, no cookie : 401` | 围栏没问题，只是**没带 token**（0.2.x 对所有请求鉴权） | 一行英文提示的"准空白"页 |

- **403 的修法（自愈）**：`sudo ./start.sh --install-service` 重跑——它会把 `connection` 信任行写进 **systemd 单元实际读取的 home** 并重启，然后自动复测。
  常见成因：用旧版脚本 `sudo` 安装时，信任行写进了 `/root/.dsh`，而服务以普通用户身份读 `/home/<用户>/.dsh`。
- **401 的修法**：首次访问要带 token，从 `--diagnose` / `dsh-web-token.txt` / journal 里取：
  `journalctl -u dsh --no-pager | grep 'dsh web:'`，访问 `https://<节点名>.<tailnet>.ts.net/?token=XXXX`，之后 30 天免 token（cookie）。

## 故障排查

| 现象 | 原因 / 处理 |
| --- | --- |
| 页面能开但一片空白、`/api` 403 | 见上一节"页面空白"；`--diagnose` 给结论，`--install-service` 重跑自愈 |
| 控制台 `Promise.withResolvers is not a function` 或 `expected property name, got '{'` | **浏览器太旧**（Firefox <121 / Chrome <119 / Safari <17.4）。升级浏览器；脚本无法修补压缩包的语法错误 |
| 访问只有一行英文 `dsh web authentication required` | 401：正常鉴权，首次要带 `?token=`（见上） |
| `crypto.randomUUID is not a function` | 用了明文 HTTP 访问。必须走 HTTPS（tailscale serve 的 https 入口） |
| 补丁报告 `pattern changed upstream` | 上游改动了那段代码，补丁跳过。功能可能仍可用，也可能失效——看具体哪一条 |
| 终端功能异常 | 原生模块没编译：`npm approve-scripts --all && npm rebuild`，或重跑 `start.sh` |
| 非 Linux | 用 `start.ps1` |
