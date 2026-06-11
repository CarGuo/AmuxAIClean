# E2E 烟雾测试报告 — 2026-06-11

> 跑法：[Scripts/e2e-smoke.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/e2e-smoke.sh) → release-built `.app` + `osascript` System Events 抓 AX tree
> 配套：[Scripts/regression.sh](file:///Users/guoshuyu/workspace/GSYCleanMac/Scripts/regression.sh) 22 case 跑代码路径，**此报告补「真启动 + 真 quit + 真 AX」一层**
> 结果：✅ **PASS**

## 一、烟雾测试七步执行结果

| Step | 内容 | 结果 |
|---|---|---|
| 0 | `pkill -f GSYCleanMac` 清残留 | ✅ |
| 1 | 子进程方式启动 `.app`，stdout/stderr 捕获 | ✅ pid 分配，stderr 1 行 |
| 2 | 主窗口就绪轮询（≤15s） | ✅ **t+1s 即就绪**（windows=2） |
| 3 | osascript 抓 AX tree | ✅ 见下 |
| 4 | `osascript -e "quit"` 优雅退出 | ✅ 命令成功执行 |
| 5 | 等待进程退出（≤10s） | ✅ **t+1s 退出** |
| 6 | exit code 检查 | ✅ **0** |
| 7 | 扫描 stderr 关键字 (fatal / SIGSEGV / SIGABRT / uncaught / abort) | ✅ **crash_hits=0 warn_hits=0** |

## 二、AX Accessibility Tree 抓取

[e2e-ax-dump.log](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/logs/e2e-ax-dump.log)：

```
frontmost=false
window_count=2
  window title=
  window subrole=AXSystemDialog
  window title=GSY Clean Mac
  window subrole=AXStandardWindow
menubar_count=2
```

**解读**：
- `AXStandardWindow` title=`GSY Clean Mac` → 主窗口正常拉起（[MainView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/MainView.swift) 渲染成功）
- `AXSystemDialog` → 是 [OnboardingScene](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/OnboardingScene.swift) / [TCCGuideView](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/Onboarding/TCCGuideView.swift) 浮在主窗口前的引导模态
- `menubar_count=2` → 一个 app menubar + 一个 status bar tray menu（[TrayController](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/AppUI/Sources/AppUI/TrayController.swift)）双双就绪
- `frontmost=false` 是因为 osascript 此时正在前台

## 三、E2E 发现的 P0 bug

### `vendors.yaml` 未被打包进 `.app`

**唯一 stderr 输出**：

```
2026-06-11 16:34:12.543 GSYCleanMac[44097:5411105] [GSYCleanMac] vendors.yaml 未找到，跳过 vendor 规则加载
```

**验证**：

```bash
find /tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app -name "*.yaml"
# (空输出)
```

**根因定位**：

[GSYCleanMacApp.swift#L467-L475](file:///Users/guoshuyu/workspace/GSYCleanMac/App/GSYCleanMacApp.swift#L467-L475) 查 `Bundle.main` 的 `Rules/vendors.yaml`，但 [GSYCleanMac.xcodeproj/project.pbxproj](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj/project.pbxproj) 的 Copy Bundle Resources phase **从未引用** `Resources/Rules/`，导致 `*.yaml` 一律不进 bundle。Debug + Release 同病。

**影响**：production 安装包里 [vendors.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendors.yaml) + [vendor_shared.yaml](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules/vendor_shared.yaml) 完全不生效，[SafetyKit RuleLoader](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit/Sources/SafetyKit/RuleLoader.swift) fallback 到代码硬编码 vendor 列表。**严重影响 production 命中精度，但不致崩溃**——和上轮 22 GUI case PASS 的事实相吻合（fallback 路径走得通）。

**修复方案**：详见 [followups.md F-0-4](file:///Users/guoshuyu/workspace/GSYCleanMac/docs/regression/2026_06_11/followups.md)（需 Xcode GUI 操作 + 重 codesign，单独提交验证）。

### 二次验证（用户当场修完）

用户在 Xcode 里把 [Resources/Rules/](file:///Users/guoshuyu/workspace/GSYCleanMac/Resources/Rules) 三个 yaml 加入了 GSYCleanMac target 的 Copy Bundle Resources phase（[pbxproj 已包含 3 个 PBXBuildFile 在 Resources phase](file:///Users/guoshuyu/workspace/GSYCleanMac/GSYCleanMac.xcodeproj/project.pbxproj)）。

```bash
$ find /tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app -name "*.yaml"
/tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app/Contents/Resources/vendors.yaml
/tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app/Contents/Resources/safe_paths.yaml
/tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app/Contents/Resources/vendor_shared.yaml
```

**re-run e2e-smoke**：

| 项 | 修前 | 修后 |
|---|---|---|
| .app 内 yaml | 0 个 | **3 个** ✅ |
| 启动 NSLog | `vendors.yaml 未找到，跳过 vendor 规则加载` | **`已加载 79 条 vendor 规则`** ✅ |
| 主窗口 | t+1s | t+2s（多了 yaml 解析时间，可接受） |
| 退出 | exit 0 | exit 0 ✅ |
| crash 关键字 | 0 | 0 ✅ |

> **F-0-4 已闭环** —— production 安装包从「vendor 规则零生效」恢复到「79 条规则全部加载」，[SafetyKit](file:///Users/guoshuyu/workspace/GSYCleanMac/Packages/SafetyKit) 命中精度归位。


## 四、E2E 烟雾结论

| 维度 | 结论 |
|---|---|
| 启动 | ✅ 1 秒主窗口可见 |
| 主窗口 | ✅ AXStandardWindow + title="GSY Clean Mac" |
| Onboarding | ✅ AXSystemDialog 正确叠加 |
| Tray | ✅ menubar_count=2 |
| 退出 | ✅ osascript quit 1 秒回收，exit 0 |
| 崩溃 | ✅ 0 |
| 发现 bug | 🟡 1 个 P0：vendors.yaml 未打包 → 已记 F-0-4 |

## 五、可重复跑法

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Release \
    -derivedDataPath /tmp/gsy-e2e-dd build

./Scripts/e2e-smoke.sh /tmp/gsy-e2e-dd/Build/Products/Release/GSYCleanMac.app \
                       docs/regression/2026_06_11/logs

cat docs/regression/2026_06_11/logs/e2e-smoke.log
cat docs/regression/2026_06_11/logs/e2e-ax-dump.log
cat docs/regression/2026_06_11/logs/e2e-runtime.log
```
