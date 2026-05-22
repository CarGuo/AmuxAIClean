# Treemap 派磁盘可视化工具深调

> 调研对象：GrandPerspective（macOS 开源 treemap）、ncdu（命令行 NCurses）、Disk Inventory X（macOS 开源 treemap，KDirStat 算法）
> 调研时间：2026-05
> 调研动机：为 GSYCleanMac 是否切入"纯磁盘可视化"方向提供决策依据

---

## 一、对比矩阵（先看结论）

| 维度 | GrandPerspective | ncdu | Disk Inventory X |
|------|------------------|------|------------------|
| 平台 | macOS 11+（Apple Silicon / Intel） | 任意 POSIX（macOS 通过 brew/MacPorts） | macOS 10.13–10.15（已停更，未签名） |
| 开源协议 | GPL | MIT | GPL |
| 当前版本 | 3.6.4（2026-03） | 2.9.2 (Zig) / 1.22 (C LTS) | 1.3（2019-12，最后一版） |
| **可视化方式** | [图] Treemap（方块，Squarified 类布局） | [列] 文本树 + 相对长度条（hash/half-block/eighth-block） | [图] Treemap（KDirStat slice-and-dice 算法） |
| **下钻交互** | 鼠标悬停高亮 -> 点击锁定 -> Cmd+/Cmd- 缩放，方向键键盘导航 | hjkl/方向键，Enter/l 进入，h/<- 返回 | 三联视图同步：左侧大纲点击 / treemap 双击进入 / Cmd-U 返回父级 |
| **过滤：文件类型** | [Y] 强（基于 file type / extension / package status 的可组合 filter test） | [警告] 仅 `--exclude pattern`（glob 黑名单） | [警告] 通过"按类型分组统计"侧栏过滤显示，不在扫描层 |
| **过滤：size 阈值** | [Y] filter test 支持 size 比较 | [N] 无（只能在排序后手动看） | [N] 无（仅排序） |
| **过滤：修改日期** | [Y] creation/modification/last-access 时间染色 + filter test | [Y] 仅"按 mtime 排序"（需 `-e` 扩展模式），无范围过滤 | [N] 无 |
| **删除支持** | [Y] 移到废纸篓（首选项中开启） | [Y] `d` 键，可自定义 `--delete-command`（如 `gio trash`） | [Y] 移到废纸篓（网络卷会警告） |
| **硬链接 / 云文件** | [Y] Time Machine / 云文件专项支持 | [Y] shared/unique 列、`-L` 跟随符号链接 | [警告] 物理 vs 逻辑大小切换 |

---

## 二、GrandPerspective（macOS · Treemap · GPL）

### 2.1 功能树

```
GrandPerspective 3.6.4
├── 扫描 / 数据获取
│ ├── 选择磁盘卷或任意文件夹 [目录] 任意路径
│ ├── 全卷扫描（Show Entire Volume） [目录] 任意路径
│ ├── 全盘访问权限自动检测与提示（FDA prompt，3.6.1+）
│ ├── 增量刷新（Refresh，仅重扫变化目录，3.0+）
│ ├── 完整重扫（Re-scan）
│ ├── 扫描时排除（Exclude when scanning）—— 复用 filter
│ └── 后台线程扫描（不阻塞 UI）
│
├── 可视化（Treemap） [图] treemap
│ ├── 染色方案（Color by）
│ │ ├── name / extension / file type / parent folder / top folder
│ │ ├── level in hierarchy
│ │ ├── size [图] treemap
│ │ ├── creation time / modification time / last access time
│ │ └── 自定义文件类型->颜色映射
│ ├── 调色板（Palette，可切换 / 按规模排序）
│ ├── 显示对象切换：files / packages+files / packages+folders
│ ├── 仅显示文件夹（3.5.3+）
│ ├── 显示焦点（Display Focus，控制深度，3.3+）
│ └── 视图变化动画
│
├── 导航 / 下钻
│ ├── 鼠标悬停 -> 选中高亮（同时高亮所在文件夹链）
│ ├── 单击锁定选区 / 再次单击解锁
│ ├── 滚轮上调 / 下调 Selection Focus
│ ├── Cmd[ / Cmd]：选区焦点上下移动
│ ├── Cmd+ / Cmd-：放大 / 缩小（进入子目录树）
│ ├── 方向键键盘导航选区（需先锁定）
│ └── 工具栏 Focus / Zoom 控件
│
├── 过滤 & 蒙版（Filters / Masks） [图] treemap
│ ├── Filter Test 维度：name / path / size / file type / hard-link / package
│ ├── 三种用法
│ │ ├── Mask：在视图上半透明遮罩
│ │ ├── Filter：从视图剔除
│ │ └── Exclude on scan：扫描期跳过
│ ├── 默认过滤器（如 "no cloud files"）
│ └── Filter 与 test 持久化到偏好设置
│
├── 操作（Actions on selection）
│ ├── Open（默认应用打开）
│ ├── Reveal in Finder
│ ├── Quick Look（Spacebar）
│ ├── Search by name
│ └── Delete -> 移至废纸篓 [Y] 删除
│
├── 多视图 / 对比
│ ├── Refresh / Re-scan：清理前后对比
│ └── Twin / Duplicate view：同一份数据双视图
│
├── 持久化 / 导出
│ ├── 保存扫描结果（压缩格式，3.5+ 体积缩小 10×）
│ ├── 重载历史扫描
│ ├── 导出为图片
│ └── 导出为文本
│
├── 偏好设置
│ ├── 默认 filter / display focus / palette
│ ├── 删除按钮启用开关
│ └── 国际化（10+ 语言，含简中）
│
└── 特殊场景
 ├── 硬链接：分析 Time Machine 备份
 └── 云存储：iCloud Drive 等远程文件
```

### 2.2 三大对比要点

- **可视化**：[图] treemap，方块面积 ∝ 文件大小；同文件夹的文件聚拢但内部位置非语义化。
- **下钻**：鼠标驱动为主（悬停 -> 单击锁定 -> Cmd+/Cmd- 缩放），辅以键盘方向键（需先锁定选区）。"双击进入"在 GP 里被 Cmd+ 取代。
- **过滤**：**三家中最强**——多维 filter test（含 size、时间、类型、硬链接、package）可同时驱动 mask/filter/exclude 三种行为，并能持久化复用。

### 2.3 信息来源

1. 官方主页 features 列表：https://grandperspectiv.sourceforge.net/
2. 帮助文档"Navigating views"：https://grandperspectiv.sourceforge.net/HelpDocumentation/NavigatingViews.html
3. Views 主帮助页：https://grandperspectiv.sourceforge.net/HelpDocumentation/Views.html
4. SourceForge 项目页（含源码、bug、feature requests）：https://sourceforge.net/projects/grandperspectiv/

---

## 三、ncdu（跨平台 · 文本树 · MIT）

### 3.1 功能树

```
ncdu 2.9 / 1.22
├── 扫描 / 数据源
│ ├── 扫描指定目录 [目录] 任意路径
│ ├── 多线程扫描（-t N，2.5+）
│ ├── 单文件系统模式（-x / --one-file-system）
│ ├── 跟随 / 不跟随符号链接（-L / --follow-symlinks）
│ ├── CACHEDIR.TAG 识别（--include-caches / --exclude-caches）
│ ├── Linux 伪文件系统过滤（--include-kernfs，仅 Linux）
│ ├── 扩展模式 -e（owner/perms/mtime，约 +30% 内存）
│ └── 配置文件支持（/etc/ncdu.conf、~/.config/ncdu/config）
│
├── 导入 / 导出
│ ├── -o file：导出 JSON
│ ├── -O file：导出二进制（2.6+，内置压缩、可流式浏览大于内存的树）
│ ├── -f file：导入；导入态自动禁用删除/shell/refresh 防误操作
│ ├── -c / --compress：JSON 用 Zstandard 压缩
│ ├── --compress-level 1–19
│ └── --export-block-size（二进制块大小）
│
├── 浏览器交互（Browser） [列] 文本树
│ ├── 列展示
│ │ ├── 大小（disk-usage 或 apparent-size，`a` 切换）
│ │ ├── 相对长度条（hash / half-block / eighth-block 三种字符）
│ │ ├── 百分比 / 条形图 / 两者 / 都不显示（`g` 循环）
│ │ ├── 子项数（`c` 切换，--show-itemcount）
│ │ ├── mtime（`m` 切换，需 -e）
│ │ └── shared / unique 硬链接列（`u` 循环）
│ ├── 排序
│ │ ├── n：文件名（再按反向）
│ │ ├── s：文件大小
│ │ ├── C：子项数
│ │ ├── M：mtime（需 -e）
│ │ ├── t：目录优先 / 不优先
│ │ ├── --enable-natsort：自然排序
│ │ └── --sort col[-asc|-desc]：默认列
│ └── 显示开关
│ ├── e：显示 / 隐藏 "hidden" 与 excluded 文件
│ ├── --si：1000 进制单位
│ └── --color off | dark | dark-bg
│
├── 命令行键位（重点） [列] 文本树
│ ├── ?：帮助 + 键位 + 关于
│ ├── ↑/↓ 或 j/k：上下选择 （vim 风）
│ ├── ->/Enter/l：进入选中目录
│ ├── <-/</h：返回父级
│ ├── d：删除（移除文件/目录，`--confirm-delete` 默认 on） [Y] 删除
│ ├── r：刷新当前目录（--enable-refresh / --disable-refresh）
│ ├── b：在当前目录 spawn shell（--enable-shell / --disable-shell）
│ ├── i：显示选中项详细信息
│ ├── g：切换百分比 / 条形图 / 两者 / 无 （重点）
│ ├── e：显示/隐藏隐藏文件 （重点）
│ ├── a：disk usage ↔ apparent size 切换
│ ├── n / s / C / M / t / u / c / m：见上方排序与列开关
│ └── q：退出（--confirm-quit 可选）
│
├── 过滤
│ ├── --exclude pattern（可重复）
│ ├── -X / --exclude-from file（pattern 列表，按行）
│ └── [N] 无 size 阈值过滤；[N] 无 mtime 范围过滤（仅"按 mtime 排序"）
│
├── 安全限制
│ ├── -r：只读（一次=禁删，二次=同时禁 shell）
│ ├── --disable-delete / --disable-shell / --disable-refresh
│ ├── --confirm-quit / --confirm-delete
│ └── --delete-command 'cmd'（替换内置删除，例 `gio trash --` 或 `rm -ri --`）
│
└── UI 反馈级别
 ├── -0 静默
 ├── -1 仅进度文本
 ├── -2 全屏 ncurses（推荐）
 └── -q / --slow-ui-updates（远程低带宽）
```

### 3.2 三大对比要点（含命令行交互专项）

- **可视化**：[列] **纯文本树**——单层目录列表 + 相对长度 ASCII 条；不是 treemap 也不是 sunburst，但靠 SSH 跨网仍可用，是它的核心差异化。
- **下钻**：键盘驱动，**hjkl/方向键 + Enter/l 进入 + h/<- 返回**（vim 风格），不存在鼠标交互。
- **过滤能力**：仅 glob 黑名单（`--exclude` / `-X`），**没有 size 阈值或 mtime 范围过滤**；只有"按 mtime 排序"（需 `-e`）。

**命令行交互专项（按用户要求）**：

| 键 | 行为 |
|----|------|
| `h` `j` `k` `l` | 左/下/上/右（vim 导航） |
| `<-` / `<` / `h` | 进入父目录 |
| `->` / `Enter` / `l` | 进入子目录 |
| `d` | 删除（默认弹确认） |
| `g` | 在 "百分比 / 条形图 / 两者 / 无" 之间循环 |
| `e` | 显示 / 隐藏隐藏文件与被排除项 |
| `a` | 切换"实际占用磁盘空间"（disk usage）/"apparent size" |
| `n` `s` `C` `M` | 按 名/大小/子项数/mtime 排序（再按一次反向） |
| `t` | 目录优先开关 |
| `c` | 显示子项数列 |
| `m` | 显示 mtime 列（需 -e） |
| `u` | shared/unique 硬链接列循环 |
| `i` | 显示详细信息 |
| `r` | 刷新 / 重扫当前目录 |
| `b` | 在当前目录开启 shell |
| `?` | 帮助 |
| `q` | 退出 |

### 3.3 信息来源

1. 官方页面：https://dev.yorhel.nl/ncdu
2. ncdu 2.9 manpage：https://dev.yorhel.nl/ncdu/man
3. Forgejo 仓库（开发主分支）：https://code.blicky.net/yorhel/ncdu/
4. Homebrew 公式：https://formulae.brew.sh/formula/ncdu

---

## 四、Disk Inventory X（macOS · Treemap · GPL · 已停更）

### 4.1 功能树

```
Disk Inventory X 1.3
├── 扫描 / 启动
│ ├── 启动时弹出"已挂载卷"窗口（实时更新挂载/卸载） [目录] 任意路径
│ ├── 扫描整卷或任意文件夹 [目录] 任意路径
│ ├── Finder 上下文菜单插件 "Open in Disk Inventory X"（手动安装）
│ ├── 拖拽文件夹到 Dock 图标即扫描
│ └── 1.3：扫描速度提升约 2×
│
├── 三联主视图（选区跨视图同步）
│ ├── 左：文件层级大纲（File hierarchy）
│ ├── 中：Treemap（KDirStat slice-and-dice 算法） [图] treemap
│ │ ├── 大方块 = 大文件
│ │ ├── 颜色 = 文件类型（MP3、PDF、… 自动分配）
│ │ ├── 配色范围：所有打开窗口共享色 / 单窗口独立色
│ │ └── Retina 全分辨率渲染（1.2+）
│ └── 右：Kind Statistic（按文件类型统计）
│
├── 下钻 / 导航
│ ├── 在 treemap 上单击 -> 选中文件，三视图同步 [图] treemap
│ ├── 在大纲上点击 / 展开 -> treemap 同步高亮
│ ├── 双击进入子文件夹（zoom in）
│ ├── Cmd-U：选择父级（"select parent"）
│ ├── Refresh 全部 / 单文件 / 单文件夹
│ └── 主窗口分割：垂直 / 水平切换
│
├── 检视面板
│ ├── Inspector 窗口：所选文件/夹的详细信息
│ ├── 物理大小（已用簇）vs 逻辑大小（内容大小）切换
│ └── 忽略 Creator Code（统一显示为 "PDF File" 等）
│
├── 选择列表（Selection List 抽屉） [图] treemap
│ ├── 列出某 kind 的全部文件（或全部 kind 的所有文件）
│ ├── 类似 iTunes 的搜索框 [目录] 任意路径
│ ├── 排序列（kind / size / 名称等）
│ └── 通过 kind statistic 右键菜单或 Window 菜单打开
│
├── 操作
│ ├── Reveal in Finder
│ ├── Move to Trash [Y] 删除
│ ├── 网络卷上的删除会弹警告（无法移废纸篓，只能直删）
│ └── Refresh 单项后视图重算
│
├── 偏好设置 / Toolbar
│ ├── 工具栏（1.0+）
│ ├── 文件列表与统计抽屉的小字号选项
│ └── Finder 上下文菜单插件安装开关
│
└── 系统适配
 ├── 1.0 (2005)：Mac OS X 10.3+
 ├── 1.2 (2019)：64-bit Intel only、暗色模式、Retina
 ├── 1.3 (2019)：macOS Catalina（10.13–10.15）
 └── [警告] 未签名 / 未公证；2020 年后停止更新
```

### 4.2 三大对比要点

- **可视化**：[图] treemap（KDirStat slice-and-dice）+ 文件类型 kind 列表（统计面板）。**没有 sunburst**——sunburst 是 DaisyDisk/Filelight 路线，不属于这一派。
- **下钻**：**三联同步视图**是 DIX 的招牌——左大纲 / 中 treemap / 右 kind 统计联动；treemap 上**双击进入**子目录，Cmd-U 返回父级，可与大纲点击混用。
- **过滤**：**最弱**——没有真正的过滤器，只能用"按 kind 在 selection list 里筛"模拟过滤；无 size 阈值、无 mtime 维度。

### 4.3 信息来源

1. 官方主页（含截图链接、KDirStat / WinDirStat 谱系说明）：https://www.derlien.com/
2. 截图与三联视图说明：https://www.derlien.com/screenshots/index.html
3. Release Notes（功能演进 0.7 -> 1.3）：https://www.derlien.com/releasenotes/index.html
4. 谱系算法源头 KDirStat：https://kdirstat.sourceforge.net/

---

## 五、横向深对比（重点三项）

### 5.1 可视化方式

| | treemap（方块） | sunburst（环形） | 文本树 |
|---|---|---|---|
| GrandPerspective | [Y] Squarified 类，支持多种染色（含 size、mtime、ctime） | [N] | [N] |
| ncdu | [N] | [N] | [Y] NCurses，相对长度条三种字符样式 |
| Disk Inventory X | [Y] KDirStat slice-and-dice，按 kind 染色 | [N] | [N]（仅左侧大纲，是 outline 不是 disk-usage 文本树） |

> 这一派**没有人做 sunburst**——sunburst 派的代表是 DaisyDisk（macOS 商业）、Filelight（KDE）。所以本文档对 sunburst 的讨论严格按"未涉及"对待。

### 5.2 下钻交互

| | 鼠标点击进入 | 双击进入 | 键盘导航 |
|---|---|---|---|
| GrandPerspective | 单击锁定 -> Cmd+ 缩放进入 | 不直接支持（Cmd+ 替代） | [Y] 方向键、Cmd[/Cmd]/Cmd+/Cmd- |
| ncdu | [N]（无鼠标） | [N] | [Y] vim 风（hjkl）+ 方向键 + Enter |
| Disk Inventory X | [Y] 三视图任一处单击同步 | [Y] treemap 双击进入 | [警告] Cmd-U 返回父级（其余靠鼠标） |

### 5.3 过滤能力

| | 文件类型 | size 阈值 | 修改日期 |
|---|---|---|---|
| GrandPerspective | [Y] filter test 多维（含 file type / extension / package） | [Y] filter test 含 size 比较 | [Y] 染色 + filter test 含三种时间维度 |
| ncdu | [警告] 仅 glob `--exclude` / `-X` | [N] | [警告] 仅按 mtime 排序（需 `-e`），无范围过滤 |
| Disk Inventory X | [警告] 仅"按 kind 分组在 selection list 里筛"，不在扫描层 | [N] | [N] |

**结论**：**GrandPerspective 在过滤维度遥遥领先**，是工程上最值得参考的对象；DIX 在交互范式（三联同步）上独到；ncdu 在跨平台与无 GUI 场景独占。

---

## 六、总结：GSYCleanMac 切入"纯磁盘可视化"方向的最小特性集

这三家代表了 macOS 上"纯磁盘可视化"派的成熟范式：**GrandPerspective 是过滤之王，DIX 是三联交互之王，ncdu 是命令行 / 远程之王**。三家都不做 sunburst，所以如果 GSYCleanMac 想把"可视化"做成卖点，**走 treemap 就能站在巨人肩上，做 sunburst 才是切入差异化（对标 DaisyDisk）**。

无论选哪条路线，**最小特性集（MVP）**应当满足：

### 最小特性集清单（MVP）

1. **扫描内核**
 - 任意路径扫描（卷 / 文件夹 / Finder 拖拽进入） [目录]
 - 后台并发扫描，UI 不阻塞（参考 ncdu `-t`、GP 后台线程）
 - 增量刷新（GP 3.0 的 Refresh：只重扫变化目录）
 - 排除规则：CACHEDIR.TAG、符号链接选项、单文件系统选项
 - 全盘访问权限自动检测与引导（GP 3.6.1 的 FDA prompt）

2. **可视化（建议先 treemap，后补 sunburst 做差异化）**
 - Squarified treemap，方块面积 ∝ size [图]
 - 至少 3 种染色方案：按文件类型 / 按修改日期 / 按 size（GP 三件套）
 - 同文件夹文件视觉聚拢
 - 显示焦点深度调节（GP Display Focus）

3. **下钻交互（融合三家精华）**
 - 鼠标悬停 -> 高亮路径链 + 底部状态栏显示路径与大小（GP）
 - 单击锁定选区 / 双击进入子目录（DIX）
 - Cmd+/Cmd- 缩放 + Cmd-U 返回父级 + 方向键键盘导航（GP + DIX）
 - 三联同步视图：左大纲 / 中 treemap / 右 kind 统计（DIX 王牌）

4. **过滤（直接对标 GP，这是护城河）**
 - 多维 filter test：name / path / size / file type / mtime / hard-link / package
 - 三种使用方式：mask（半透明）/ filter（剔除）/ exclude on scan
 - filter 持久化到偏好（用户能复用）
 - 内置常用预设：`>100MB`、`30 天未访问`、`no cloud files`

5. **操作**
 - Reveal in Finder
 - Quick Look 预览（Spacebar） [目录]
 - 移至废纸篓 [Y]（默认隐藏开关防误删，参考 GP 偏好）
 - 删除文件夹时显式警告（GP 文档专门强调"含被 mask/filter 的文件也会一起进废纸篓"）

6. **数据持久化**
 - 保存扫描结果（压缩格式，参考 GP 3.5 的 10× 压缩）
 - 重新加载并对比（Refresh / Twin view）
 - 导出图片 + 导出文本 / JSON

7. **系统集成**
 - Finder 上下文菜单 "Open in GSYCleanMac"（DIX 1.0 范式）
 - 多语言（至少简中 / 英）
 - 暗色模式 + Retina 全分辨率渲染

### 不属于 MVP 但值得作为 V2 差异化

- Sunburst（环形）视图——避开三家、对标 DaisyDisk
- 多线程并行扫描（ncdu 2.5 路线）
- 二进制格式导出，支持大于内存的目录树流式浏览（ncdu 2.6 的 `-O`）
- Time Machine 备份分析（GP 硬链接路线）
- 云存储（iCloud Drive）分析（GP cloud filter 路线）

---

## 附：综合信息来源

- GrandPerspective 官方 features：https://grandperspectiv.sourceforge.net/
- GrandPerspective 帮助文档：https://grandperspectiv.sourceforge.net/HelpDocumentation/GrandPerspectiveHelp.html
- ncdu 项目主页：https://dev.yorhel.nl/ncdu
- ncdu 2.9 manpage：https://dev.yorhel.nl/ncdu/man
- ncdu 源码仓库（Forgejo）：https://code.blicky.net/yorhel/ncdu/
- Disk Inventory X 主页：https://www.derlien.com/
- Disk Inventory X release notes：https://www.derlien.com/releasenotes/index.html
- KDirStat（DIX 算法源头）：https://kdirstat.sourceforge.net/
