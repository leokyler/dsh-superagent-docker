# dsh-superagent-docker

把 [dsh-superagent](https://github.com/deepseek-ai/dsh-superagent-prototype)（DeepSeek Harness 的一个研究原型：把 GitHub 上的请求变成工单，每个工单在自己的 agent session 与目录里执行）跑在容器里。

上游**没有镜像、也没有 Dockerfile**，本仓库补上它，并解决容器化的两个硬问题：面板只监听 loopback，以及安装流程本来是交互式的。

> 非官方项目。dsh-superagent 本身是 MIT 协议的研究代码：先读它的 README，给它**专门的** GitHub 账号，千万别用你自己的。

```
docker compose up -d --build     # 构建并启动
docker compose logs -f           # 读带 token 的面板地址
docker compose exec superagent gh-agent auth login --web   # 登录 agent 账号
```

然后在面板里：选模型 → 填仓库与 agent CLI → 把自己加进白名单 → 配 worker 的 prepare 命令。之后在 Issue 里 `@<agent-login> <请求>` 即可。

## 为什么不能直接 `docker run`

**面板只肯在 loopback 上服务。** `src/app/http.ts` 要求 webserver 绑 `127.0.0.1`，且每个管理请求的 `Host` 头必须是 `127.0.0.1:<port>` 或 `localhost:<port>`。所以入口脚本起一条

```
socat 0.0.0.0:13082 → 127.0.0.1:3082
```

compose 发布 `127.0.0.1:3082 → 13082`，浏览器仍访问 `localhost:3082`，校验通过。原生 Linux 可以 `DSH_SUPERAGENT_ACCESS=host` + `--network host` 跳过代理。

**安装流程是交互式的。** 上游假定有一个 agent 一次问一个问题，然后执行 `dsh superagent --from-default-profile web`、`dsh plugin add`、`gh auth login` 和面板里的一堆保存。`entrypoint.sh` 把可自动化的部分做掉，且**幂等**：建 profile、装 bundle、写 `cordis.patch.yml`、生成 `gh-agent` wrapper、在 tmux 里起服务，并每 60 秒自愈一次（**只在 exit 1 时**重启；2 和 3 需要人）。

## 前置

- Docker（WSL 里用 Docker Desktop 的话要先开 WSL 集成）
- 约 5 GB 磁盘，能访问 `github.com`、`cli.github.com` 和 npm
- 容器内可达的模型 provider
- 一个**专用** GitHub 账号（对测试仓库有写权限）

## 快速开始

```bash
mkdir -p repos
docker compose up -d --build
docker compose logs -f superagent     # 末行会是 http://localhost:3082/?token=…
```

面板左侧选 **Superagent**，按 Overview 提示逐项完成配置。

登录 agent 账号（推荐，设备码流程，在自己的浏览器里粘贴 8 位码）：

```bash
docker compose exec superagent gh-agent auth login --web
docker compose exec superagent gh-agent api user --jq .login
```

或者非交互：把 token 写进 `gh-token` 并打开 compose 里的 secret 挂载，入口脚本会自动登录。

## 没有 compose 也能跑

镜像不含任何 compose 特性，所以任何 Docker 兼容 CLI 都行——包括只实现 `build`/`run` 的（例如 Windows 上的 `wslc`）。参数与 compose 一一对应：

```bash
docker build -t dsh-superagent:local .
mkdir -p repos
docker run -d --name dsh-superagent --restart unless-stopped \
  -p 127.0.0.1:3082:13082 \
  -e DSH_SUPERAGENT_ACCESS=proxy \
  -e DSH_SUPERAGENT_PUBLISHED_PORT=3082 \
  -v dsh-home:/home/node/.dsh \
  -v "$PWD/repos":/home/node/src \
  dsh-superagent:local
```

原生 Linux 可以去掉 `-p`，改用 `--network host -e DSH_SUPERAGENT_ACCESS=host`。把 `docker` 换成你的 CLI 即可，`logs` / `exec` / `rm` 同名。

网络到不了 Docker Hub 时，用 `--build-arg BASE_IMAGE=<镜像源>/library/node:24-bookworm` 换个源构建。

## 面板里要配的四块

| 位置 | 内容 |
|---|---|
| Sources → GitHub | 仓库 `owner/name`、agent CLI `/home/node/.local/bin/gh-agent` |
| Policy → GitHub | 允许派活的 login（列表为空时任何请求都进不来） |
| Execution | 目录根（例如 `/home/node/src/agent-work`）+ 下面的 prepare 命令 |
| Prompts → Delivery | commit 作者、是否允许 auto-merge（默认否） |

prepare 命令（给每个工单建 worktree，取自挂载目录里的 clone）：

```bash
git -C /home/node/src/widgets fetch --no-tags \
  "https://github.com/$DSH_SUPERAGENT_GITHUB_REPOSITORY.git" \
  "${DSH_SUPERAGENT_GITHUB_PR_HEAD:-HEAD}:refs/dsh-superagent/$DSH_SUPERAGENT_TICKET" \
  && git -C /home/node/src/widgets worktree add \
  -b "agent/$DSH_SUPERAGENT_NAME" "$DSH_SUPERAGENT_DIR" \
  "refs/dsh-superagent/$DSH_SUPERAGENT_TICKET"
```

试玩期把 `eval` 模式留在 `observe`：主动工作只被记录成“would accept”，不烧 worker session。

## `patches/` 里那个补丁

`0001-detect-the-service-process-on-node-24.patch`：在当前的 Node 上，`ps -o ucomm=` 显示的是**线程名**，服务进程会显示成 `MainThread` 而不是 `node`。不修的话 `status` 永远数不到 pid、恒返回 1，自愈循环会反复重启一个健康的服务。Dockerfile 在 clone 之后自动应用；上游修好后删掉这个文件即可（循环会跳过不存在的补丁）。

## 验证

```bash
docker compose exec superagent scripts/dsh-superagent status; echo "exit=$?"
```

| exit | 含义 | 处理 |
|---|---|---|
| 0 | 正常 | 去 Issue 里 `@<agent-login> <请求>` |
| 1 | 没跑/崩了 | 看最新的 `.artifacts/dsh-superagent-superagent-*.log` |
| 2 | 某个部件报错 | `status` 会打印 `errors`，重启不管用 |
| 3 | 等配置 | 面板 Overview 会链到缺的那一项 |

## 配置项

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `DSH_SUPERAGENT_ACCESS` | `proxy` | `proxy` 走 socat；`host` 用于 `--network host` |
| `DSH_SUPERAGENT_PORT` | `3082` | 容器内 DSH webserver 端口 |
| `DSH_SUPERAGENT_PROXY_PORT` | `13082` | socat 端口，compose 发布的就是它 |
| `SUPERAGENT_PORT` | `3082` | 宿主机上浏览器打开的端口 |
| `DSH_SUPERAGENT_SUPERVISE` | `1` | 60 秒自愈循环 |
| `SUPERAGENT_REPOS` | `./repos` | 挂到 `/home/node/src` 的宿主目录 |
| `GH_TOKEN_FILE` | `/run/secrets/gh-token` | 可选，非交互登录 |
| `DSH_SUPERAGENT_STATE_DIR` | `$HOME/.dsh/state/superagent` | 插件的 SQLite、锁与 shim 目录 |

构建参数：`DSH_VERSION`（默认 `0.2.1-rc.3`，必须满足 bundle 的 `engines.dsh`）、`SUPERAGENT_REF`、`WITH_GIT_LFS=1`。

## 数据与重置

数据都在 `dsh-home` 卷里（DSH sessions、profiles、凭据、`orchestrator.sqlite`），升级前先备份。`docker compose down -v` 会清掉团队与工单，但 `repos/` 里的 clone 不受影响。

## 隔离

**容器就是隔离**。里面 worker 与 router 预设以 `danger-full-access`、`node` 用户运行，所以只挂载允许它读与推的东西——别把你的 home 目录挂进去。上游的替代方案是专用 OS 账号，容器等于把这步省了。

## 打包状态

- 镜像由 CI 构建（`.github/workflows/build.yml`）：Dockerfile、补丁应用、入口脚本前置、bundle 构建都会被跑一遍。
- 这套配置在**同一上游 commit 的宿主机安装**上做过端到端验证（触发 → 评估 → 工单 → worktree → commit → PR → 合并后工单自动结束）。
- 未覆盖：Feishu、通过第二个账号开启 auto-merge、GitHub Enterprise Server（上游不支持）。

## 许可

本仓库文件 MIT（见 `LICENSE`）。dsh-superagent 与 DeepSeek Harness 为 DeepSeek Harness Team 的 MIT 项目，此处仅作为构建输入；本仓库与其无隶属关系。
