# AmuxAIClean 发版流程（Release）

本文档说明当前维护者如何构建 release 产物，以及哪些产物只是签名包、哪些产物已经走完 Apple Notary 公证。

适用范围：维护者本地发版、贡献者复现产物、fork 项目者替换为自己的签名链路。

---

## 一、当前发布口径

当前项目采用维护者本地发布路径：

1. **本地维护者发布路径**：`Scripts/build_release.sh` 使用 [AmuxAIClean.xcodeproj](../AmuxAIClean.xcodeproj) 里的 Release 配置构建。当前 Release 配置是 `Manual + Developer ID Application: SentenceEnd Inc (W6H34N9728)`。
2. **注意**：`codesign --verify` 只能证明签名结构完整；公开分发闭环还需要 Apple Notary `Accepted`、`stapler staple` 和 `spctl` 校验。

---

## 二、本地构建

### 发布源码必须包含已完成的产品状态

<!-- v2026.09.20：1.6.4 曾从只提交本轮修复的 worktree 打包，遗漏原工作区尚未提交的普通工作台，导致界面回退。 -->
用户要求在当前产品上修复并打包时，发布基线是当前完整产品状态。先核对 tracked diff 和
untracked 源文件，将已有界面、资源、关联业务与回归测试一并纳入发布范围；不能因为改动
尚未提交，或并非当前轮次编写，就自行排除。确需裁剪已有功能时必须获得明确的范围指令。

提交前保存待发布文件清单及内容摘要，提交后逐项核对 Git 中的文件内容与该基线一致。
若使用独立 worktree，创建后也要核对同一基线；`clean` 只说明没有未提交差异，不能证明
用户已经完成的功能都被包含。最终 provenance 必须指向通过该核对的提交。

有界面入口的发布必须同时核对生产入口、对应实现与本地化资源进入构建。离屏渲染可作为
布局证据；没有在安装产物上实际交互时，仍明确标注“未做运行交互验收”。

### Developer ID 签名但不公证

适合快速验证 release 构建、内部传递候选包，不能等价为 Gatekeeper 公共分发闭环。

```bash
./Scripts/build_release.sh --no-notarize
```

产物：

- `dist/AmuxAIClean.app`
- `dist/AmuxAIClean-<version>.dmg`
- `dist/AmuxAIClean-<version>.dmg.sha256`
- `dist/AmuxAIClean-<version>.provenance.json`

脚本会验证：

- `xcodebuild -configuration Release` 构建成功
- `.app` 通过 `codesign --verify --strict`
- 最终 DMG 使用与 App 相同的 Developer ID Application 身份签名
- Hardened Runtime 已启用
- `Info.plist` 版本号与 build number 一致
- DMG 内隐藏的 `.build-provenance.json` 与 `dist` sidecar 记录 HEAD、clean/dirty 状态和源码差异 fingerprint
- 在所有签名操作完成后生成 `dist/AmuxAIClean-<version>.dmg.sha256`

### Developer ID 签名并公证

适合正式对外分发候选包。提交前应确认 app bundle 内没有测试数据、私密配置或不该上传给 Apple 的文件。

```bash
AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary \
./Scripts/build_release.sh --notarize
```

脚本会依次执行：

1. 构建 Developer ID 签名 `.app`
2. 生成源码 provenance sidecar，并把同一内容作为隐藏文件嵌入最终 DMG
3. 生成最终 DMG
4. 从 App 读取 Developer ID Application identity，并用同一 identity 签名 DMG
5. **只把最终 DMG** 交给 `xcrun notarytool submit --wait`
6. staple DMG
7. `spctl -a -vv -t open --context context:primary-signature` 校验 DMG
8. 对已 staple 的最终 DMG 再做 `codesign`、`hdiutil verify`、私有挂载点只读回挂，并核对内部 App 签名、安装链接与 provenance
9. 对完成上述校验的最终 DMG 生成 SHA256

该流程不再创建或提交 App notary zip，也不单独 staple App。Apple Notary 以最终分发容器 DMG 为提交对象，同时检查其中已经 Developer ID 签名的 App。

可配置环境变量：

```bash
VERSION=x.y.z                     # 可选；默认读取工程 MARKETING_VERSION
BUILD_NUMBER=1234
BUILD_DIR=build/release
DIST_DIR=dist
DMG_PATH=dist/AmuxAIClean-x.y.z.dmg
AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary
NOTARY_TIMEOUT=45m
```

`PASTE_MIND_NOTARY_KEYCHAIN_PROFILE` 只作为迁移兼容变量保留；新配置应使用 `AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE`。

`BUILD_DIR`、`DIST_DIR` 和 `DMG_PATH` 都可以传绝对或仓库相对路径；脚本会先统一为绝对路径，避免相对 `DIST_DIR=dist` 被再次拼成 `dist/dist/...`。

无需证书、不构建产物、不访问网络的发布合同检查：

```bash
./Scripts/test_release_contract.sh
```

该检查固定 `写入源码 provenance → 打 DMG → 签 DMG → 只提交 DMG → staple DMG → Gatekeeper 验收 DMG → 最终 SHA256` 顺序，并防止 App zip 公证或 App staple 重新混入流程。

如果工作树含未提交改动，脚本不会把产物伪装成纯 HEAD：`sourceState` 会记录为 `dirty`，并以 NUL-safe 路径枚举对 tracked diff 与 untracked 文件内容生成与 checkout 绝对路径无关的 SHA256 fingerprint（中文、空格、制表符和换行文件名不会被误解析）。脚本还会在构建后重新计算 fingerprint；构建期间源码或 HEAD 变化会直接终止发布。正式发布仍建议先提交并推送；需要在提交前制作候选 DMG 时，sidecar 与 DMG 内记录可保留准确溯源证据。

### 只构建 app

适合快速验证 Release 签名配置，不生成 DMG，也不提交 Apple Notary。

```bash
./Scripts/build_release.sh --app-only
```

---

## 三、版本 Tag 与源码固定

<!-- v2026.09.20：发布必须先固定完整源码的 tag，禁止构建后才补一个未经对应核对的版本标记。 -->
完整发布源码通过测试、提交并与工作区基线核对后，先固定版本 tag，再从该 tag 对应的
干净源码构建。开始构建前验证 `HEAD` 等于 tag 指向的 commit；完成后验证 provenance 的
`gitHead` 与同一 commit 一致。分支名或版本字符串相同均不能代替这项核对。

```bash
RELEASE_VERSION=x.y.z
git tag "v${RELEASE_VERSION}" -m "Release ${RELEASE_VERSION}"
git push origin "v${RELEASE_VERSION}"
```

已推送的版本 tag 不得移动。若源码需要再修改，使用新版本 tag 重新构建和验证。
tag 只固定源码；公证与实际交互尚未完成时，仍只能按对应验证边界交付测试包。

---

## 四、用户侧完整性校验

维护者发布 DMG 与对应 `.sha256` 文件后，用户下载可在终端：

```bash
shasum -a 256 AmuxAIClean-x.y.z.dmg
```

把命令输出与 release 中 `*.sha256` 文件首列做比对，一致即代表下载完整、未被中间网络替换。

SHA256 只证明字节一致，不证明 Apple Gatekeeper 已接受。Gatekeeper 接受要看 Developer ID、Notary、staple 和 `spctl` 结果。

---

## 五、fork 项目签名

fork 后请替换自己的 Team / signing 配置：

1. Debug：可保持 Automatic signing，选择自己的 Apple Development Team。
2. Release：使用自己的 `Developer ID Application: <Name> (<TeamID>)`。
3. Notary：用 `xcrun notarytool store-credentials` 保存自己的 keychain profile，再通过 `AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=<profile>` 调用 `Scripts/build_release.sh --notarize`。

官方文档：

- Notarizing macOS software before distribution: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Customizing the notarization workflow: <https://developer.apple.com/documentation/security/customizing-the-notarization-workflow>
- Hardened Runtime: <https://developer.apple.com/documentation/security/hardened_runtime>
