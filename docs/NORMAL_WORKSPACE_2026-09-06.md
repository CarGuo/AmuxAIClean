# 普通模式工作台 · 2026-09-06

## 改动原因与范围

v2026.09.06：原普通模式只有 Smart Care 单页，磁盘分析、卸载、维护等已有能力集中在专业侧栏。
此次根据用户提供的参考图改为顶部「分析 / 清理 / 卸载 / 优化 / 状态」工作台，保留现有
蓝绿强调色、圆角科技材质、浅色/深色适配与 Smart Care 动效。没有修改专业模式的页面结构。

v1.6.3：按用户后续要求移除普通模式「卸载」栏目，当前导航为「分析 / 清理 / 优化 / 状态」。
同时移除普通工作台的卸载路由和不再使用的 vendor 参数，避免只隐藏按钮留下不可达页面；
专业模式卸载入口保留。新版本通过发布脚本的 `VERSION=1.6.3 BUILD_NUMBER=207` 构建。

参考的是交互结构和功能分组，没有复用竞品图标、星球素材或源码：

- [Kivo 官方功能说明](https://kivoapp.cc/zh/index.html)
- [Squarified Treemaps 原始论文](https://vanwijk.win.tue.nl/stm.pdf)
- [Apple host_statistics](https://developer.apple.com/documentation/kernel/1502546-host_statistics)

## 功能对照与明确差距

| 方向 | 本次实现 | 尚未对齐的部分 |
|---|---|---|
| 分析 | 复用 ScanCoordinator 的启动磁盘/主目录/自选文件夹扫描；真实占用矩形图、目录下钻、面包屑、名称搜索、分页列表、Finder 定位、普通模式审阅后移到废纸篓 | 不越过现有 HOME 删除边界；不把读取范围当成可删范围 |
| 清理 | 保留 Smart Care 扫描阶段选择、开发缓存提醒、按风险审阅、一键清理、AI 复核与终态反馈 | 不采用竞品的缓存永久删除行为 |
| 优化 | 复用现有用户态维护任务和启动项查看 | 未实现 Kivo 宣传的 22 项管理员维护；不承诺「一键加速」 |
| 状态 | CPU、内存、磁盘、电池、Wi-Fi/以太网实时读数；最多 60 秒迷你曲线、运行时间与系统热状态 | 未新增 GPU、传感器温度数值、进程排行/排序/置顶 |

上述差距是当前实现事实，不代表已与用户确认放弃后续需求。

## 数据与生命周期合同

- 面积只来源于非 pending 的 allocated bytes，不是 logical bytes，更不是可清理容量。
  扫描不完整的下界有说明；零大小、受限、尚未测得大小的项目保留在列表，不分配假面积。
- 图中最多 40 个独立项目；v2026.09.06 可读性修复后还按实际方块尺寸归组，小到放不下
  名称与容量的项目合并为「较小项目」，原比例面积保留。图外提供始终可读的数量、容量
  与「查看明细」按钮，点击后左侧显示这一组的精确成员并可分页、返回全部。
  分组、明细和布局在同一后台 projection 中计算，统计与地图合计不随明细分页变化。
  搜索、排序、宽数组聚合由可取消后台任务执行，发布必须匹配 scan/session/path/revision。
- 普通分析拥有独立结果状态，但与 Professional、Smart Care 共用 PrimaryScanAdmissionRegistry。
  页面离开取消生产者及按需 Tree 任务；已完成结果保留。清理成功后要求显式重扫，不自动扫盘。
- 目录精确测量终态使用 `childrenCacheVersion`，必须与整树 revision 一起观察。
  本次行为测试暴露并修复了仅订阅整树 revision 导致下钻后一直显示加载的缺陷。
- 清理入口经过 `DeletionInteractionCoordinator` 的 Normal intent，确认前与交接提交前均核验
  同一 `deletionPresentationSourceRevision`。receipt 之前的拒绝只能显示非模态说明。
  独立 `storage-analysis` 来源保证其它页面也能失效旧结果；不沿用 Tree 入口的通知忽略规则。
- 系统采样在 actor 上执行，只有小型不可变 DTO 进入 UI；窗口离开活跃状态时停止采样。
  CPU/网络速率需要两次真实采样，不预填曲线。电池不存在、暂未采样和不可读取分别呈现。
- 网络通过 `NET_RT_IFLIST2` 读取本机活动 Wi-Fi/以太网的原生 64 位计数，避免高流量时
  32 位计数溢出以及与虚拟隧道重复计量，不发送网络请求。
  磁盘卡直接观察现有 SystemProbeStore，物理空闲与系统可回收估算保持独立。
- 新文案集中在原 String Catalog，均有 `zh-Hans` / `en`，导航使用显式 enum → key 映射。
- 页面导航先撤销 Smart Care 可见性，再取消旧扫描/AI；旧报告只能在清理页呈现。
  删除审阅、历史记录与文件夹选择占用主窗口的统一 modal 闸门；审阅关闭后的提交必须等到
  实际 dismissal 回调，不能抢占尚未释放的系统 sheet。

## 验证与下一步

本轮达到 **C3**，尚无 C4。

- 新增 17 项聚焦测试通过：矩形图面积/分组/搜索，真实 fixture 扫描与下钻，离开/旧 revision，
  删除确认/交接拒绝，原生 CPU/64 位网络读数及离屏渲染。
- 九包全测通过：ScanKit、SafetyKit、AppUI、HeuristicKit、LogKit、BrewKit、FileSearchKit、AIKit、TestHarness。
  AppUI 最终命令为 `swift test --parallel --num-workers 4`，其余为 `swift test --parallel`。
- 目标 Debug 构建 `BUILD SUCCEEDED`；仅有未使用 AppIntents.framework 的 metadata 提取提示。
- `git diff --check` 通过；71 条新增文案的 en / zh-Hans 均完整，多语言全量校验通过。
- 离屏检查覆盖内容区 1280×700：分析页英文深色/中文浅色、清理页中文浅色、状态页英文深色。
  目录数据来自临时 fixture；状态读数来自本机只读采样。没有启动 App，也没有执行本轮 UI 真删。

[完整验证记录与失败日志](../build/validation/normal-workspace-2026-09-06/summary.md)，
[深色分析预览](../build/ui-preview/normal-workspace/workspace-analyze-en-dark.png)，
[浅色分析预览](../build/ui-preview/normal-workspace/workspace-analyze-zh-Hans-light.png)。

首次 AppUI 全测暴露两点，保留失败记录而不降低检查要求：

- 动态导航键改为显式映射，原多语言 orphan 检查保持不变。
- 原生采样测试原先假定 150ms 内必有新 CPU ticks，不符合
  [XNU 一秒统计缓存窗口](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/host.c)。
  调整为产品的两秒采样周期，仍强制断言新读数存在且有限；重复 ticks 保持未知的行为另有测试。

第二次默认并行全测中，既有 20,200 候选性能测试出现 1.084s / 1s 的临界超时；
同一测试单独通过（整项 0.474s），随后完整 AppUI 在四进程下通过。未改该实现或性能门槛，
默认最大并行的资源争用波动仍作为验证限制保留。

**未做运行交互验收。** 按 [AGENTS.md](../AGENTS.md)，启动 App 前需明确获得用户同意：建议使用一次
持续运行，依次检查五个入口、扫描/取消/重扫、矩形图下钻与返回、两种语言/外观、清理确认取消。
真实移动仅使用 NSTemporaryDirectory 中预先建立的 fixture，不能用真实 HOME 文件测试真删。
禁止用反复启动/立即退出替代这些操作。

## 小方块可读性修复

后续用户截图指出 `private` 及旁边小矩形缺少容量/文字的问题，当前修复和验证结果见
[TREEMAP_READABILITY_2026-09-06.md](TREEMAP_READABILITY_2026-09-06.md)。上文 C3/C4
记录保留首次工作台交付时的证据，不覆盖后续实际验证结果。
