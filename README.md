# Spotion

在原生 macOS Spotlight（`⌘ + Space`）中直达 Codex CLI / Claude Code 会话：

- **Search & Open**：Spotlight 搜索历史会话（标题 / 项目名 / 目录），回车在终端中以正确的工作目录 resume。
- **Quick Create**：Spotlight 内运行 "New Codex Session" / "New Claude Session" 动作，内联输入 Prompt，回车拉起终端新会话（macOS 26 Tahoe 的 Spotlight Actions）。
- **后台常驻**：菜单栏 app 监听 `~/.codex` 与 `~/.claude` 的会话变化，持续同步 Spotlight 索引。

不依赖 Raycast / Alfred，纯原生入口。

## 环境要求

- macOS 26 (Tahoe)+
- Xcode 26+（本仓库构建命令通过 `DEVELOPER_DIR` 指定，不要求 `xcode-select` 切换）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`；`.xcodeproj` 由 `project.yml` 生成，不入库）

## 构建与安装

```bash
make build      # Debug 构建
make test       # 单元测试
make install    # Release 构建并安装到 /Applications，然后启动
```

**Spotlight 相关验证一律针对 `/Applications/Spotion.app` 拷贝**——DerivedData 里的重复拷贝会干扰
LaunchServices / App Intents 注册。注册异常时执行 `make reset-registration`。

## 排障

- Spotlight 搜不到会话：先在 app 的 Settings → Index 里跑自检（CSUserQuery 直查索引），命中 >0 说明索引正常、
  是 Spotlight UI 侧问题——检查 系统设置 → Spotlight 中 Spotion 的结果开关，或稍等系统索引；命中 =0 则点 Reindex。
- 会话数据来源：`~/.codex/sessions/**/rollout-*.jsonl`（标题在 `~/.codex/session_index.jsonl`）、
  `~/.claude/projects/<escaped-cwd>/<uuid>.jsonl`。仅有界读取（head/tail），不整读大文件。
