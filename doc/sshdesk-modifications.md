# sshdesk 修改记录

日期：2026-09-10
部署位置：Parallels VM（Ubuntu 26.04，10.211.55.4，UUID `{126c5c5b-7e4c-450c-9314-3b1a56acccb4}`）
软件版本：sshdesk 0.4.5（venv 安装于 `/opt/sshdesk/venv/`，上游 https://github.com/rylena/sshdesk）
用途：通过 `ssh -t rarnu@10.211.55.4 desktop` 把 VM 桌面以 Kitty 图形协议流式显示到 ExGhostty 终端。

与官方 0.4.5（main 分支）逐一 diff 的结果：**代码改动只有 1 个文件（render/kitty.py），配置改动只有 1 项（SSHDESK_SCALE）**。wrappers、sshd 配置均为官方原版。

## 修改清单

| # | 位置 | 类型 | 解决的问题 |
|---|------|------|-----------|
| 1 | `/opt/sshdesk/venv/lib/python3.14/site-packages/sshdesk/render/kitty.py` | 代码补丁 | 桌面图像只占终端中央一小块；期望占满终端 |
| 2 | `/etc/sshdesk/rarnu.conf`：`SSHDESK_SCALE` 从 `auto` 改为 `1.0` | 配置 | 图像不断刷新并越缩越小（直到 0.25 才停） |

## 修改 1：kitty.py 渲染布局补丁

### 问题

连接后桌面图像只显示在终端中央一小块（约 15% 面积），不随终端放大。

### 根因

原版 `_layout()` 的缩放逻辑是**只缩不放**：

```python
scale = min(1.0, usable_width / desktop_width, usable_height / desktop_height)
```

代码注释原文："Let the terminal center a native-size desktop instead of upscaling it on the server."
VM 桌面分辨率为 1352x1012，远小于终端像素区（约 3492x2167），`min(1.0, ...)` 把缩放比钉死在 1.0，图像按原生像素居中显示，自然只占一小块。

### 改法（要点）

核心思路：**图像的显示尺寸始终铺满终端（保持桌面宽高比），缩放交给终端完成**——Kitty 图形协议的 placement 支持 `c`/`r` 单元格跨度键，终端会把图像缩放到 placement 占据的格子区域（包括放大）。传输的内容像素仍 capped 在「桌面原生分辨率 × render_scale」，因为传更多像素不会增加细节，只会白白增加采集、编码和传输开销。

具体改动（补丁已存于 VM，原文件备份为同目录 `kitty.py.bak`）：

1. `KittyTile` 新增 `cell_columns`、`cell_rows` 字段（placement 的格子跨度）。
2. `_layout()`：
   - `display_scale = min(usable_width/desktop_w, usable_height/desktop_h)`（**去掉了 1.0 上限**），据此算出铺满终端的格子区域 `cell_columns × cell_rows`；
   - `content_scale = min(1.0, display_scale) * render_scale`，内容图像尺寸 = 桌面原生分辨率 × content_scale；
   - 返回值从 4 元组改为 6 元组（追加内容图像的宽高）。
3. tile 裁切与 diff 检测：从「格子坐标 × 格子像素」改为按「内容图像 / 格子区域」的比例换算（`content_cell_width/height`），因为内容像素和显示格子不再是 1:1。
4. Kitty placement 命令追加 `c=<cell_columns>,r=<cell_rows>`，让终端执行缩放（diff 更新和全量更新两处都改）。
5. `changed_percentage` 与 FULL 更新判定改用完整图像尺寸；图像尺寸变化时也触发 FULL 更新。

### 注意

这是对**已安装包**的直接补丁，重新安装或升级 sshdesk（`pip install --upgrade`）会覆盖。升级后需重打补丁；可用以下命令核对补丁是否还在：

```bash
grep -c "cell_columns" /opt/sshdesk/venv/lib/python3.14/site-packages/sshdesk/render/kitty.py
# 补丁在时应输出多处匹配（原版为 0）
```

## 修改 2：SSHDESK_SCALE 固定为 1.0

### 问题

连接后图像会不断刷新，且越缩越小，直到缩到 0.25 倍才停止。

### 根因

`/etc/sshdesk/rarnu.conf` 由官方 `scripts/install-server.sh` 生成，默认 `SSHDESK_SCALE=auto`。auto 模式下 `session/direct.py` 的 `_maybe_adjust_render_scale()` 会根据性能统计**周期性下调 render_scale**（下限 0.25），每次下调都改变图像尺寸并触发全量重渲染——表现为"不断刷新、越缩越小"。

### 改法

```diff
-SSHDESK_SCALE=auto
+SSHDESK_SCALE=1.0
```

`1.0` 是合法区间的上限（`0.25–1.0`），固定后 `_auto_render_scale=False`，自适应缩放完全关闭。配合修改 1，图像始终以桌面原生分辨率采集、由终端放大铺满，不再自动缩小。

## 未改动的部分（保持官方原版）

以下为官方安装脚本的标准产物，diff 验证一致，升级/重装无需特别处理：

- `/usr/local/bin/sshdesk-forced-command`（md5 与官方 scripts/ 一致）
- `/usr/local/bin/sshdesk-server`、`sshdesk-agent-ssh` 等（pip 生成的 entry-point 软链）
- `/etc/ssh/sshd_config.d/90-sshdesk-rarnu.conf`（官方文档模板：Match User rarnu → ForceCommand + 禁转发等收紧项）
- `/etc/sshdesk/rarnu.conf` 其余键（DISPLAY/XAUTHORITY/RUN_AS/Wayland 环境等，安装时按机器生成）

## 相关环境改动（非 sshdesk 本体，但服务于同一场景）

记录在案，重装 VM 时需要重做：

1. `/etc/terminfo/x/xterm-ghostty`——xterm-ghostty 的系统级 terminfo（2026-09-10 用 root 从 Mac 侧 `infocmp -x | tic -x -` 安装）。因为 rarnu 的 ForceCommand 会拦截 ExGhostty ssh 集成的 terminfo 自动安装脚本（任何 exec 请求都被转给 sshdesk agent），只能以 root 预装。装了它之后，VM 上的 tmux 能直接读到 Sync 能力（mode 2026 同步输出）。
2. Mac 侧执行过 `ghostty +ssh-cache --add=rarnu@10.211.55.4`，让 ssh 集成跳过对这台机器的 terminfo 安装尝试（避免 ForceCommand 导致的 `error.InstallFailed` 警告）。
3. VM 上另行安装了 tmux 3.6（用于复现/验证 tmux 场景，非 sshdesk 依赖）。

## 验证方式

- 补丁完整性：diff `/opt/sshdesk/.../render/kitty.py` 与同目录 `kitty.py.bak`，或对照上游 `src/sshdesk/render/kitty.py`。
- 功能验证：`ssh -t rarnu@10.211.55.4 desktop`，预期图像铺满终端（保持桌面宽高比、上下或左右留边居中），长时间运行不自动缩小。
