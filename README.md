# DiskChrona

一个 macOS 菜单栏小工具，持续记录磁盘上文件大小的变化，帮你回答「磁盘空间是被谁、在什么时候吃掉的」。

- 菜单栏实时显示每分钟的文件大小净变化，展开可看近期趋势和增长最多的文件
- **概览**：卷可用空间趋势、按位置堆叠的空间变化图、增长热点目录、正在写入的位置
- **排行**：按文件或目录排序，可切换「文件大小 / 分配空间」口径与「累计增长 / 净变化」排序
- **原始记录**：每一条检测到的变化，以及单个文件的完整变化历史
- 监控范围为整个磁盘，可排除缓存等高频写入目录；可选忽略系统虚拟内存交换文件
- 退出或暂停监控的时段在图表中显示为灰色缺口，其间的变化按恢复后的检测时间记录
- 「复制 AI 分析提示词」：生成一段提示词，交给本地 AI agent 以只读方式分析记录数据库

DiskChrona 基于 FSEvents，只对文件做 `lstat`，**不读取文件内容**，所有数据只保存在本机。

## 安装

系统要求：macOS 15 及以上，Apple Silicon（arm64）。

1. 从 [Releases](../../releases) 下载 `DiskChrona-<版本>.dmg`
2. 打开 dmg，把 `DiskChrona.app` 拖到「应用程序」
3. 首次打开：应用为本地签名、未经公证，macOS 会拦截。打开「系统设置 → 隐私与安全性」，点「仍要打开」；或在终端执行：

   ```sh
   xattr -dr com.apple.quarantine /Applications/DiskChrona.app
   ```

4. （推荐）在「系统设置 → 隐私与安全性 → 完整磁盘访问权限」中允许 DiskChrona，否则邮件、信息等受保护目录的变化无法统计。应用内「设置」页有直达按钮。

DiskChrona 只在菜单栏运行，不显示 Dock 图标；从菜单栏面板点「打开主窗口」进入完整界面。关闭窗口后仍在后台监控，在「设置」中可开启登录时启动。

## 数据

- 数据库：`~/Library/Application Support/DiskChrona/DiskChrona.sqlite`（SQLite，WAL 模式）
- 历史默认保留 30 天，容量预算默认 500 MiB，超出时自动收缩最旧的记录，均可在「设置」中调整
- 「设置 → 清除本 App 历史」会删除全部变化历史，不影响被监控的文件本身

## 从源码构建

需要 Xcode 16 / Swift 6 工具链。

```sh
./build-app.sh          # release 构建，生成 build/DiskChrona.app 和 build/DiskChrona-<版本>.dmg
./run.sh                # debug 构建并重启应用，开发时使用
swift test              # 运行测试
```

版本号在 `build-app.sh` 的 `VERSION` 中修改。
