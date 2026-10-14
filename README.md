# 超级剪切板 移动端（clip-relay-mobile）

Flutter 免费配套 App（Android / iOS）：与电脑端通过取件码中转互传文本、图片、文件，端到端加密。协议见 [`relay-protocol/PROTOCOL.md`](relay-protocol/PROTOCOL.md)。

## 结构

| 路径 | 作用 |
|---|---|
| `app/` | Flutter App |
| `packages/relay_crypto/` | 取件码中转加密协议 v1 的 Dart 实现 |
| `relay-protocol/` | 协议文档与跨语言测试向量 |
| `ci/` | GitHub Actions 辅助脚本 |
| `app/lib/core/` | 配置（`config.dart`）、安全存储（`store.dart`）、授权传输加密与 entitlement 验签（`license_crypto.dart`）、签名请求客户端（`relay_api.dart`）、绑定与设备信任（`binding.dart`）、模型 |
| `app/lib/transfer/` | 发送（`send_service.dart`：哈希 → 建会话 → 流式加密到 8 MiB 块文件 → 上传 → commit，含续传/重包裹）、取件（`receive_service.dart`：验签 → 解包 → 下载 → 流式解密 → SHA-256 校验）、块传输（`background_transport.dart` = `background_downloader`，`block_transport.dart` = 测试/备用） |
| `app/lib/app/app_controller.dart` | 唯一的界面状态（`ChangeNotifier`）：凭证、设备、待取件、传输进度、未完成发送 |
| `app/lib/platform/` | 分享接收（`receive_sharing_intent`）、iOS 系统粘贴按钮（`UIPasteControl` 平台视图）、存相册/存文件/分享 |
| `app/lib/ui/` | 中文界面：绑定页、取件 / 发送 / 设备三个标签页 |
| `app/ios/Share Extension/` | iOS 分享扩展（`RSIShareViewController`，经 App Group 交给主 App 发送） |

状态管理只用 `ChangeNotifier` + `ListenableBuilder`，不引入额外状态库：业务逻辑全部在可注入依赖的服务类里（HTTP client、块传输、存储、工作目录），单元测试用假服务器直接驱动。

## 本地开发

授权服务器地址与两把 RSA 公钥通过 `--dart-define-from-file` 注入，仓库不包含任何私密信息：

```bash
cd app
cp config/relay.example.json config/relay.json   # 填入地址与 public.pem / transport-public.pem 的 base64 正文（单行）
flutter run --dart-define-from-file=config/relay.json
```

* 公钥写单行 base64（去掉 PEM 头尾与换行）；多行 PEM 经 Xcode 构建链传递会失败。
* Release 构建强制 HTTPS 且必须配置两把公钥；Debug 未配置公钥时跳过验签、明文传输，仅供开发。
* 扫码绑定的服务器地址取自二维码；授权码绑定使用 `licenseServerUrl`。

测试：

```bash
(cd packages/relay_crypto && dart test)
(cd app && flutter analyze && flutter test)
```

与 Node 参考实现的双向校验测试依赖私有服务端仓库，在本仓库中自动跳过；跨语言一致性由 `relay-protocol/test-vectors/` 保证（向量中的 RSA 密钥仅用于测试）。

Android Release 签名：在 `app/android/key.properties` 写入 `storeFile`、`storePassword`、`keyAlias`、`keyPassword`；文件不存在时使用 debug 签名。

## GitHub Actions

| 触发 | 执行 |
|---|---|
| Pull request、推送到 `main` | 静态检查 + 单元测试 |
| 手动运行（Actions → Build → Run workflow） | 测试 + APK + IPA，产物在运行页面的 Artifacts 下载；可选择 iOS 导出方式 |
| 推送 `v*` 标签（如 `v1.0.0`） | 测试 + APK + IPA，并创建同名 GitHub Release 附带安装包 |

版本号：标签构建取标签（`v1.2.3` → `1.2.3`），其他构建取 `pubspec.yaml`；构建号为运行序号 `run_number`。

发布：

```bash
git tag v1.0.0 && git push origin v1.0.0
```

### Secrets（Settings → Secrets and variables → Actions）

| 名称 | 必填 | 内容 |
|---|---|---|
| `RELAY_CONFIG_JSON` | 是 | `config/relay.json` 的完整内容，`licenseServerUrl` 必须为 HTTPS |
| `ANDROID_KEYSTORE_BASE64` | 否 | `base64 -i release.jks`；未配置时 APK 使用 debug 签名 |
| `ANDROID_KEYSTORE_PASSWORD` / `ANDROID_KEY_ALIAS` / `ANDROID_KEY_PASSWORD` | 随上 | keystore 密码、别名、密钥密码 |
| `IOS_CERTIFICATE_P12_BASE64` | 否 | 签名证书导出的 p12：`base64 -i cert.p12`；未配置时输出未签名 IPA |
| `IOS_CERTIFICATE_PASSWORD` | 随上 | p12 密码 |
| `IOS_PROFILE_BASE64` | 随上 | `com.clipboard.manager.mobile` 的描述文件：`base64 -i app.mobileprovision` |
| `IOS_SHARE_EXTENSION_PROFILE_BASE64` | 随上 | `com.clipboard.manager.mobile.ShareExtension` 的描述文件 |

可选变量（Variables）`IOS_EXPORT_METHOD`：标签构建使用的 iOS 导出方式，默认 `ad-hoc`（可选 `development`、`app-store`、`enterprise`）。证书类型须与导出方式匹配：`development` 用开发证书，其余用发布证书；ad-hoc / development 描述文件需包含要安装的设备 UDID。

生成 Android keystore：

```bash
keytool -genkeypair -v -keystore release.jks -alias release -keyalg RSA -keysize 2048 -validity 10000
```

CI 使用 `ci/ios_manual_signing.py` 在构建机上临时把 Runner 与 Share Extension 的 Release 配置切换为手动签名（团队 ID 与描述文件名从描述文件读取），仓库中的工程保持自动签名。未签名 IPA 仅可用于重签名，不能直接安装。

## iOS 签名准备（需 Apple 开发者账号）

工程文件已包含 Share Extension target、App Group 授权文件、`Embed App Extensions`（位于 `Thin Binary` 之前）与 Podfile 配置，模拟器可直接构建。真机/上架还需：

1. Xcode 打开 `app/ios/Runner.xcworkspace`，`Runner` 与 `Share Extension` 两个 target 的 *Signing & Capabilities* 选择同一 Team。
2. 在开发者后台注册 App ID `com.clipboard.manager.mobile` 与 `com.clipboard.manager.mobile.ShareExtension`，两者都启用 App Groups 并勾选 `group.com.clipboard.manager.mobile`（Xcode 自动签名会提示创建）。
3. `Runner` 的 Associated Domains 等其他能力不需要；Camera / Photos 用途说明已在 `Info.plist`。
4. 出口合规：仅使用系统/标准加密算法，提交时按实际情况回答加密问题。

分享扩展的实际分享流程（照片 App → 分享 → 超级剪切板）需在真机或模拟器 UI 中手动验证。

## Android

`applicationId com.clipboard.manager.mobile`、`cliprelay://bind` 深链、`SEND`/`SEND_MULTIPLE` 分享入口、`minSdk 24`。Android 上剪贴板一键发送仅支持文本。

## 设备信任与收件人

指纹一律由客户端根据公钥本地计算，不采用服务器下发的值。手机端为每台其他设备保存一个固定指纹：

| 状态 | 来源 | 作为收件人 | 校验其发出的取件 |
|---|---|---|---|
| 已校验 | 扫码绑定时签发二维码的电脑（指纹与二维码 `f` 一致） | 是 | 是 |
| 首次信任 | 首次在设备列表中看到的设备；用户在「设备」页确认新指纹后也回到此状态 | 是 | 是 |
| 指纹已变化 | 公钥与已保存指纹不一致 | **否** | **否**（列表显示「无法校验来源」） |
| 未启用互传 | 没有登记公钥 | 否 | — |

## 平台安全说明

* 外部打开的 `cliprelay://bind` 链接（相机 App、浏览器等）需在弹窗中显示服务器与电脑指纹并由用户确认后才绑定；随后仍执行服务器指纹比对与授权签名校验。
* Android 分享：`MainActivity` 先把 `content://` 流按清理过的文件名复制到 `cache/shared/`，再交给 `receive_sharing_intent`（插件自身按提供方给出的文件名写入缓存目录，存在路径穿越风险）；其他 App 传入的 `file://` 直接丢弃。`allowBackup=false`；明文 HTTP 仅在 debug 构建允许。
* iOS `NSAllowsLocalNetworking` 仅用于本地联调；Release 构建在 Dart 层拒绝非 HTTPS 的授权服务器地址与存储块地址。
* 收到的明文文件位于临时目录 `relay/received/`，删除取件、解除绑定或下次启动时清除。

## 上架定位

免费配套 App：界面不显示价格、购买入口或外部购买链接；未绑定时只提示「请在电脑端扫码绑定」。

## 许可证

[MIT](LICENSE)
