# PodWifi — 导盲 Pod 无线接收端（iOS）

iOS 端接收 **ESP32-S3（或任意 Pod 主控）** 通过 Wi-Fi 推来的视频与导航数据：

- **MJPEG 单目画面**（`codec=0x01`）
- **传感器 JSON**（`codec=0x10`）→ 界面面板
- **导航播报文本**（`codec=0x11`）→ 系统 TTS 朗读（新播报打断旧播报）
- **事件文本**（`codec=0x12`）→ 日志

协议：24 字节大端帧头 `'P','O' + version + codec + flags + seq + ts + w + h + len`，
与安卓端 / 鸿蒙端共用同一份定义。

> iPhone **不支持外接 UVC 相机**（只有 USB-C 的 iPad 支持），所以 iOS 侧只能走无线。
> 这就是本仓库存在的原因。

---

## 怎么得到 ipa（不需要 Mac）

1. 打开本仓库 **Actions** 页面 → 左侧 `ios-build` → 右侧 **Run workflow**
   （或直接 push 一次代码，会自动触发）
2. 等 **5~8 分钟**
3. 点进这次运行，页面底部 **Artifacts** → 下载 `PodWifi-ipa`（是个 zip）
4. 解压得到 `PodWifi-unsigned.ipa`

> 产出的是 **未签名 ipa**，所以 CI 里不需要任何 Apple 账号或证书。

---

## 怎么装到 iPhone（Windows 上做）

1. 安装 [Sideloadly](https://sideloadly.io/)（或 AltStore）
   - Windows 需要先装 **iTunes**（微软商店版即可）或 **Apple Devices** 应用，Sideloadly 依赖它的驱动
2. 手机 USB 连电脑，信任此电脑
3. Sideloadly 里选择 `PodWifi-unsigned.ipa`，`Apple ID` 填你自己的 **Apple ID**
   （免费账号即可；密码只进 Sideloadly，不会到任何服务器）
4. 点 Start，输入 Apple ID 密码与双重认证验证码
5. 手机上：设置 → 通用 → VPN 与设备管理 → 信任你的开发者证书
6. 打开 App，把地址填成 Pod 的 `IP:5000`，点连接

**限制（免费 Apple ID）**：签名 **7 天过期**，到期重签即可；最多同时 3 个自签 App。
付费开发者账号（$99/年）签名为 1 年。

---

## ⚠️ 仓库可见性与费用

| 仓库类型 | macOS runner | 说明 |
|---|---|---|
| **Public** | **免费、不限量** | 推荐。本仓库只有 App 源码，无任何密钥 |
| Private | 2000 分钟/月，但 **macOS 按 10 倍算**，且**要求账号绑定支付方式** | 一次构建约 6 分钟 = 60 分钟额度，约 30 次/月 |

若坚持私有：Settings → Billing → 添加支付方式并把 Actions 花费上限设为 $1，
这样只扣免费额度，不会真扣钱。

---

## 本地结构

```
.github/workflows/ios-build.yml   CI 流水线（macos-15 + XcodeGen + 无签名构建）
project.yml                       XcodeGen 工程描述（不把 .xcodeproj 入库）
PodWifi/
  PodWifiApp.swift                入口
  ContentView.swift               界面：地址输入 / 画面 / 传感器 / 播报 / 日志
  WifiStereoReceiver.swift        TCP + 帧解析 + 分发
  Info.plist                      含 NSLocalNetworkUsageDescription（缺了必连不上局域网）
push_to_github.bat                一键推送（可选，本地用）
```

## 版本

- v1.0.0 / 2026-11-01：首版，MJPEG + 传感器 + TTS
