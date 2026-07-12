# GSYCleanMac 发版流程（Release）

本文档说明当前维护者如何构建 release 产物，以及哪些产物只是签名包、哪些产物已经走完 Apple Notary 公证。

适用范围：维护者本地发版、贡献者复现产物、fork 项目者替换为自己的签名链路。

---

## 一、当前发布口径

当前项目有两条明确路径：

1. **本地维护者发布路径**：`Scripts/build_release.sh` 使用 [GSYCleanMac.xcodeproj](../GSYCleanMac.xcodeproj) 里的 Release 配置构建。当前 Release 配置是 `Manual + Developer ID Application: SentenceEnd Inc (W6H34N9728)`。
2. **GitHub Actions 公开 workflow 路径**：仓库 CI 没有 Developer ID 私钥，仍只能构建无私钥的 ad-hoc 产物，并通过 SHA256 给用户做完整性校验。

不要把这两条路径混在一起：`codesign --verify` 只能证明签名结构完整；公开分发闭环还需要 Apple Notary `Accepted`、`stapler staple` 和 `spctl` 校验。

---

## 二、本地构建

### Developer ID 签名但不公证

适合快速验证 release 构建、内部传递候选包，不能等价为 Gatekeeper 公共分发闭环。

```bash
VERSION=1.5.9 ./Scripts/build_release.sh --no-notarize
```

产物：

- `dist/AmuxAIClean.app`
- `dist/AmuxAIClean-<version>.dmg`

脚本会验证：

- `xcodebuild -configuration Release` 构建成功
- `.app` 通过 `codesign --verify --strict`
- Hardened Runtime 已启用
- `Info.plist` 版本号与 build number 一致

### Developer ID 签名并公证

适合正式对外分发候选包。提交前应确认 app bundle 内没有测试数据、私密配置或不该上传给 Apple 的文件。

```bash
VERSION=1.5.9 \
AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary \
./Scripts/build_release.sh --notarize
```

脚本会依次执行：

1. 构建 Developer ID 签名 `.app`
2. 打包 app notary zip
3. `xcrun notarytool submit --wait`
4. `xcrun stapler staple` app
5. `spctl -a -vv -t exec` 校验 app
6. 生成 DMG
7. 提交 DMG 到 Apple Notary
8. staple DMG
9. `spctl -a -vv -t open --context context:primary-signature` 校验 DMG

可配置环境变量：

```bash
VERSION=1.5.9
BUILD_NUMBER=1234
BUILD_DIR=build/release
DIST_DIR=dist
DMG_PATH=dist/AmuxAIClean-1.5.9.dmg
AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE=amux-notary
NOTARY_TIMEOUT=45m
```

`PASTE_MIND_NOTARY_KEYCHAIN_PROFILE` 只作为迁移兼容变量保留；新配置应使用 `AMUX_CLEAN_NOTARY_KEYCHAIN_PROFILE`。

### 只构建 app

适合快速验证 Release 签名配置，不生成 DMG，也不提交 Apple Notary。

```bash
./Scripts/build_release.sh --app-only
```

---

## 三、GitHub Actions tag release

发版流程仍绑定到形如 `v1.x.y` 的 git tag：

```bash
git tag v1.5.9 -m "Release 1.5.9"
git push origin v1.5.9
```

`tag` 推送后，GitHub Actions 会跑 [.github/workflows/release.yml](../.github/workflows/release.yml)，并产出：

- `GSYCleanMac-<version>.dmg`
- `GSYCleanMac-<version>.dmg.sha256`
- `GSYCleanMac-<version>.app.zip`
- `GSYCleanMac-<version>.app.zip.sha256`

当前 workflow 没有 Developer ID 私钥和 Notary 凭据，因此不要把 GitHub Actions 产物描述为已公证产物。若要 CI 也走 Developer ID + Notary，需要额外接入证书导入、notarytool profile/API key 与 secrets 管理。

---

## 四、用户侧完整性校验

Release 页面同时挂 `.sha256` 文件，用户下载后可在终端：

```bash
shasum -a 256 GSYCleanMac-1.5.9.dmg
shasum -a 256 GSYCleanMac-1.5.9.app.zip
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
