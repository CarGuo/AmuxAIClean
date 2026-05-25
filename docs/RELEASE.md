# GSYCleanMac 发版流程（Release）

本文档说明 GSYCleanMac 是如何把一个 git tag 变成一份可下载的 release 产物的，以及为什么这套流程在零 Apple Developer 账号、零 GitHub Secrets 的前提下依然成立。

适用范围：维护者发版、贡献者复现产物、fork 项目者切到自己的签名链路。

---

## 一、设计原则：不公证 / 不需要 Apple Developer Program / 不需要 GitHub Secrets

GSYCleanMac 的 release 产物使用 **ad-hoc 签名**（命令形式：`codesign --sign -`），而不是 Developer ID + 公证（notarization）。这套选择的依据：

- **ad-hoc 是 Apple 官方认可的合法签名形式**，与 Rectangle、AltTab、Stats、KeyboardCleanTool 等多个流行 macOS 开源项目的发版做法一致。
- **不需要花 99 USD/年加入 Apple Developer Program**：ad-hoc 不要求开发者证书。
- **不需要把任何密钥放进 GitHub Secrets**：CI 上的签名身份是 `-`，由 GitHub runner 在构建时即时生成的临时身份，不上传、不持久化、不依赖任何外部凭证。
- **代价**：用户首次启动 `.app` 会被 Gatekeeper 拦截（提示「无法验证开发者」），需要在 系统设置 -> 隐私与安全 中点「仍要打开」。这是 ad-hoc 路径的固有体验，安装指引见 [docs/INSTALL.md](INSTALL.md)。

如果你 fork 本项目并希望走 Developer ID + 公证路径以避开 Gatekeeper 提示，参见下文「五、fork 者切到 Developer ID 公证签名」。

---

## 二、触发一次正式 release

发版流程被绑定到形如 `v1.x.y` 的 git tag。维护者只需要在本地：

```bash
git tag v1.4.0 -m "Release 1.4.0"
git push origin v1.4.0
```

`tag` 推送后，GitHub Actions 会自动跑 [.github/workflows/release.yml](../.github/workflows/release.yml)，并产出以下文件挂到对应的 GitHub Release：

- `GSYCleanMac-1.4.0.dmg`（拖拽安装包，附带 `/Applications` 软链接）
- `GSYCleanMac-1.4.0.dmg.sha256`
- `GSYCleanMac-1.4.0.app.zip`（用 `ditto -c -k --keepParent` 打的 zip，体积比 dmg 小，对自动化更新更友好）
- `GSYCleanMac-1.4.0.app.zip.sha256`

如果只想手动从 GitHub UI 触发（不打 tag），可在 Actions 页面选择 Release workflow，使用 `workflow_dispatch` 输入版本号。这种方式只构建产物上传为 artifact，不会创建 GitHub Release（受 `if: startsWith(github.ref, 'refs/tags/v')` 守门）。

---

## 三、本地复现同样的产物

CI 与本地走完全相同的脚本，只要本机有 Xcode 16+ 与 xcodegen，就可以离线复现：

```bash
# 1. 构建 .app（默认 ad-hoc 签名）
VERSION=1.4.0 ./Scripts/build_release.sh

# 2. 打 .dmg
./Scripts/make_dmg.sh \
    dist/GSYCleanMac.app \
    dist/GSYCleanMac-1.4.0.dmg

# 3. 打 .app.zip（与 CI 完全一致）
ditto -c -k --keepParent \
    dist/GSYCleanMac.app \
    dist/GSYCleanMac-1.4.0.app.zip

# 4. 算 sha256
cd dist
shasum -a 256 GSYCleanMac-1.4.0.dmg     > GSYCleanMac-1.4.0.dmg.sha256
shasum -a 256 GSYCleanMac-1.4.0.app.zip > GSYCleanMac-1.4.0.app.zip.sha256
```

注意：本地复现得到的 sha256 与 CI 不会逐字节相等——Xcode 编译产物受时间戳、本机 Xcode 小版本、本机签名身份影响，这是预期行为。CI 的 sha256 才是发布给用户校验用的权威值。

---

## 四、用户侧：sha256 校验产物

Release 页面同时挂了 `.sha256` 文件，用户下载后可在终端：

```bash
shasum -a 256 GSYCleanMac-1.4.0.dmg
shasum -a 256 GSYCleanMac-1.4.0.app.zip
```

把命令输出与 release 中 `*.sha256` 文件首列做比对，一致即代表下载完整、未被中间网络替换。

---

## 五、fork 者切到 Developer ID 公证签名（可选）

如果你希望 fork 后避开 Gatekeeper 提示，需要自己拥有 Apple Developer Program 账号，并完成以下步骤（这里只给指针，不展开）：

1. 在自己的开发机的 keychain 里准备 `Developer ID Application: <Name> (<TeamID>)` 证书。
2. 在 `Scripts/build_release.sh` 里通过 `IDENTITY="Developer ID Application: ..."` 环境变量覆盖默认的 `-`。
3. 给 GitHub Actions 配置 keychain 与签名证书的注入流程（典型做法是 `apple-actions/import-codesign-certs`），并把 `.p12` / 密码放进 fork 仓库自己的 Secrets。
4. 用 `xcrun notarytool submit` 走公证、`xcrun stapler staple` staple 票据。
5. 公证强制要求 `ENABLE_HARDENED_RUNTIME=YES`，本仓库 `project.yml` 已默认开启，无需额外修改。

官方文档（权威来源）：

- Notarizing macOS software before distribution: <https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution>
- Customizing the notarization workflow: <https://developer.apple.com/documentation/security/customizing-the-notarization-workflow>
- Hardened Runtime: <https://developer.apple.com/documentation/security/hardened_runtime>

本仓库不会在主仓内提供这条公证流水线，因为它会带来「需要 Apple Developer 账号」「需要 GitHub Secrets」两项硬依赖，与本项目「零依赖发版」的设计目标冲突。

---

## 六、release.yml 用到的所有外部 action 一览

| Action | 版本 | 用途 | 是否需要 Secret |
| --- | --- | --- | --- |
| `actions/checkout` | `v4` | 拉取仓库代码 | 否 |
| `actions/upload-artifact` | `v4` | 把 dmg / zip / sha256 上传为 workflow artifact | 否 |
| `softprops/action-gh-release` | `v2` | 在 tag 推送时创建 GitHub Release 并附产物 | 仅依赖默认注入的 `GITHUB_TOKEN`（由 GitHub 自动签发，**不属于** repo Secrets） |

说明：

- `softprops/action-gh-release` 用的是 GitHub Actions 默认下发的 `GITHUB_TOKEN`，作用域受 workflow `permissions: contents: write` 限制，仓库管理员不需要、也不应当手动配置任何 secret。
- 整个 workflow 没有 `${{ secrets.* }}` 的引用，可以在 release.yml 里 grep 验证：

  ```bash
  grep -n 'secrets\.' .github/workflows/release.yml || echo "no secrets used"
  ```

---

## 七、常见问题

**Q: 用户下载 .dmg 双击提示「无法打开"GSYCleanMac.app"，因为无法验证开发者」怎么办？**

A: 这是 ad-hoc 签名的固有行为，不是 release 失败。让用户按 [docs/INSTALL.md](INSTALL.md) 走一遍「系统设置 -> 隐私与安全 -> 仍要打开」即可，后续启动不再提示。

**Q: 我想加自动更新（Sparkle / 自研），用 dmg 还是 zip？**

A: 推荐 `.app.zip`。Sparkle 等更新框架默认就是按 zip 流式下载 + 替换 `.app`，不需要先挂载磁盘镜像；体积上 zip 也比 dmg 略小（dmg 多一个文件系统包装）。

**Q: 我重新 push 同一个 tag 会怎样？**

A: workflow 的 `concurrency.cancel-in-progress: false` 会让上一次跑完，新一次顺序执行。但 `softprops/action-gh-release` 默认是更新已有 release，所以重复 push 同 tag 会覆盖产物（不会重复创建 release）。生产实践上仍建议用新 tag（如 `v1.4.1`）替代「重发同一版本」。
