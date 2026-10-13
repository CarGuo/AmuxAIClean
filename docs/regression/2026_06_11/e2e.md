# E2E 烟雾测试报告 — 2026-06-11

> 历史记录：`regression.sh` 与只做启动/窗口/退出检查的 `e2e-smoke.sh` 均已于
> v2026.07.16 删除。本报告仅保留当时事故线索，原 PASS 已撤销为当前质量证据；它不能替代
> 业务交互 C4，也不再提供可执行跑法。
> 结果：✅ **PASS**

## 一、烟雾测试七步执行结果

| Step | 内容 | 结果 |
|---|---|---|
| 0 | `pkill -f AmuxAIClean` 清残留 | ✅ |
| 1 | 子进程方式启动 `.app`，stdout/stderr 捕获 | ✅ pid 分配，stderr 1 行 |
| 2 | 主窗口就绪轮询（≤15s） | ✅ **t+1s 即就绪**（windows=2） |
| 3 | osascript 抓 AX tree | ✅ 见下 |
| 4 | `osascript -e "quit"` 优雅退出 | ✅ 命令成功执行 |
| 5 | 等待进程退出（≤10s） | ✅ **t+1s 退出** |
| 6 | exit code 检查 | ✅ **0** |
| 7 | 扫描 stderr 关键字 (fatal / SIGSEGV / SIGABRT / uncaught / abort) | ✅ **crash_hits=0 warn_hits=0** |

## 二、AX Accessibility Tree 抓取

[e2e-ax-dump.log](file:///Users/amuxuser/workspace/AmuxAIClean/docs/regression/2026_06_11/logs/e2e-ax-dump.log)：

```
frontmost=false
window_count=2
  window title=
  window subrole=AXSystemDialog
  window title=AmuxAIClean
  window subrole=AXStandardWindow
menubar_count=2
```

**解读**：
- `AXStandardWindow` title=`AmuxAIClean` → 主窗口正常拉起（[MainView](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/MainView.swift) 渲染成功）
- `AXSystemDialog` → 是 [OnboardingScene](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/Onboarding/OnboardingScene.swift) / [TCCGuideView](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/Onboarding/TCCGuideView.swift) 浮在主窗口前的引导模态
- `menubar_count=2` → 一个 app menubar + 一个 status bar tray menu（[TrayController](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AppUI/Sources/AppUI/TrayController.swift)）双双就绪
- `frontmost=false` 是因为 osascript 此时正在前台

## 三、E2E 发现的 P0 bug

### `vendors.yaml` 未被打包进 `.app`

**唯一 stderr 输出**：

```
2026-06-11 16:34:12.543 AmuxAIClean[44097:5411105] [AmuxAIClean] vendors.yaml 未找到，跳过 vendor 规则加载
```

**验证**：

```bash
find /tmp/amux-e2e-dd/Build/Products/Release/AmuxAIClean.app -name "*.yaml"
# (空输出)
```

**根因定位**：

[AmuxAICleanApp.swift#L467-L475](file:///Users/amuxuser/workspace/AmuxAIClean/App/AmuxAICleanApp.swift#L467-L475) 查 `Bundle.main` 的 `Rules/vendors.yaml`，但 [AmuxAIClean.xcodeproj/project.pbxproj](file:///Users/amuxuser/workspace/AmuxAIClean/AmuxAIClean.xcodeproj/project.pbxproj) 的 Copy Bundle Resources phase **从未引用** `Resources/Rules/`，导致 `*.yaml` 一律不进 bundle。Debug + Release 同病。

**影响**：production 安装包里 [vendors.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendors.yaml) + [vendor_shared.yaml](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules/vendor_shared.yaml) 完全不生效，[SafetyKit RuleLoader](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift) fallback 到代码硬编码 vendor 列表。**严重影响 production 命中精度，但不致崩溃**——和上轮 22 GUI case PASS 的事实相吻合（fallback 路径走得通）。

**修复方案**：详见 [followups.md F-0-4](file:///Users/amuxuser/workspace/AmuxAIClean/docs/regression/2026_06_11/followups.md)（需 Xcode GUI 操作 + 重 codesign，单独提交验证）。

### 二次验证（用户当场修完）

用户在 Xcode 里把 [Resources/Rules/](file:///Users/amuxuser/workspace/AmuxAIClean/Resources/Rules) 三个 yaml 加入了 AmuxAIClean target 的 Copy Bundle Resources phase（[pbxproj 已包含 3 个 PBXBuildFile 在 Resources phase](file:///Users/amuxuser/workspace/AmuxAIClean/AmuxAIClean.xcodeproj/project.pbxproj)）。

```bash
$ find /tmp/amux-e2e-dd/Build/Products/Release/AmuxAIClean.app -name "*.yaml"
/tmp/amux-e2e-dd/Build/Products/Release/AmuxAIClean.app/Contents/Resources/vendors.yaml
/tmp/amux-e2e-dd/Build/Products/Release/AmuxAIClean.app/Contents/Resources/safe_paths.yaml
/tmp/amux-e2e-dd/Build/Products/Release/AmuxAIClean.app/Contents/Resources/vendor_shared.yaml
```

**re-run e2e-smoke**：

| 项 | 修前 | 修后 |
|---|---|---|
| .app 内 yaml | 0 个 | **3 个** ✅ |
| 启动 NSLog | `vendors.yaml 未找到，跳过 vendor 规则加载` | **`已加载 79 条 vendor 规则`** ✅ |
| 主窗口 | t+1s | t+2s（多了 yaml 解析时间，可接受） |
| 退出 | exit 0 | exit 0 ✅ |
| crash 关键字 | 0 | 0 ✅ |

> **F-0-4 已闭环** —— production 安装包从「vendor 规则零生效」恢复到「79 条规则全部加载」，[SafetyKit](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/SafetyKit) 命中精度归位。


## 四、E2E 烟雾结论

| 维度 | 结论 |
|---|---|
| 启动 | ✅ 1 秒主窗口可见 |
| 主窗口 | ✅ AXStandardWindow + title="AmuxAIClean" |
| Onboarding | ✅ AXSystemDialog 正确叠加 |
| Tray | ✅ menubar_count=2 |
| 退出 | ✅ osascript quit 1 秒回收，exit 0 |
| 崩溃 | ✅ 0 |
| 发现 bug | 🟡 1 个 P0：vendors.yaml 未打包 → 已记 F-0-4 |

## 五、当前状态

原快速启停脚本已经删除。Release 合同使用 `Scripts/test_release_contract.sh` 做不启动 App 的静态校验；
需要声明真实交互正确时，必须按明确场景让 App 单次持续运行并完成人工 C4。
