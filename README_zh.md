# 
<p align="center">
<img src="./img/icon.png" width="200" height="200" />
<h1 align="center">GlassyBattery</h1>
<h3 align="center">Mac 周边所有设备的电量, 汇聚于一块 Liquid Glass 面板 — 同时支持 Dock 栏、状态栏与小组件.<br><a href="./README.md">[English Version]</a></h3> 
</p>

GlassyBattery 可以获取你的 Mac 以及周边所有 Apple 或蓝牙设备的电量信息 — iPhone、iPad、Apple Watch、AirPods、妙控鼠标 / 键盘 / 触控板, 以及第三方蓝牙外设 — 无需繁琐配对, 也无需任何配置. 你可以随心选择查看方式: 悬浮于桌面之上的玻璃面板、状态栏中的实时电量图标、桌面与通知中心的小组件, 或终端中的 `glassybattery` 命令.

## 运行截图
<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./img/preview_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./img/preview.png">
  <img alt="GlassyBattery Screenshots" src="./img/preview.png" width="314"/>
</picture>
</p>

## 下拉面板

单击 Dock 图标或状态栏图标即可唤出一块无边框面板, 它直接悬浮在桌面之上 — 背后没有任何窗口容器, 只有元素本身.

- **设备胶囊.** 每台设备都是一枚半透明胶囊, 其填充长度与电量成正比, 并采用对应电量档位的颜色 — 绿色、黄色、红色. 顶部边缘骑着一枚图标 + 百分比徽标, 设备名称位于填充之上, 型号则在其下方.
- **以闪电表示充电状态.** Mac 自身的胶囊在充电时会在剩余时间前显示 ⚡; 放电时只显示时长; 充满后则显示 ⚡ *电池电量充足*.
- **悬停操作.** 将鼠标移到胶囊上, 副标题会变成一排按钮: 设置电量提醒、将设备固定为独立的状态栏图标、复制设备名称, 或将其从列表中隐藏.
- **工具栏表盘.** 网格上方悬浮着一排玻璃按钮 — 设置、功率表盘、电池健康度圆环与退出.
  - **功率表盘**在接通电源时显示电源适配器协商所得的功率 (以 140W 为满值刻度), 使用电池时则显示当前整机功耗.
  - **健康度圆环**以百分比显示 Mac 电池的剩余容量.

  两者仅在设备配有电池且 IOKit 能给出读数时出现, 因此台式 Mac 上按钮会更少.
  - **表盘单位.** 在偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown* → *Dial Unit* 中可选择这两个表盘如何标注单位 (W、%): **水印** (默认) 将其作为淡淡的字形置于数字之后; **角标**将其移入一个跨在表盘右下边缘的小玻璃圆圈中; **隐藏**则只留下数字.
- **主题.** 在偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown*中可选择玻璃的解析方式: **自适应** (默认) 会采样面板背后的桌面, 因此在任何壁纸上都保持清晰; **跟随系统**、**浅色**与**深色**则固定为指定外观.
- **面板尺寸.** 在偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown* → *Panel Size* 中可按比例缩放整块面板 — 宽度、胶囊、表盘与文字会一同变化 — 可选**小**、**默认**与**大**.

在 macOS 26 上, 以上元素 (包括小组件) 均以真正的 Liquid Glass 绘制, 让系统材质透出而非将其覆盖. 在 macOS 13–15 上, 同样的布局会以带色调的半透明填充呈现.

## 安装与使用
### 系统版本要求:
- macOS 13.0 及更高版本 (Liquid Glass 材质需要 macOS 26)  

### 安装:
前往 [Releases](../../releases/latest) 下载最新的磁盘映像, 打开后将 **GlassyBattery** 拖入“应用程序”文件夹即可.

### 使用:
- GlassyBattery 启动后默认同时显示在 Dock 栏和状态栏上, 也可以只显示其中之一.  

- 无需任何手动配置, GlassyBattery 启动后会自动搜索所有支持隔空电量获取的设备. 
- 您可以单击 Dock 图标 / 状态栏图标、或添加小组件查随时看周边设备的电量信息. 
- 利用 `Nearcast` 功能还可以随时查看局域网中属于你的其他 Mac 及其外设的电量.
- 通过 `BatteryBridge` (需在偏好设置中开启), 本机上的其他应用可以经由本地 API 添加自己的设备, 图标可用内置图标或任意 SF Symbol, 详见 [BatteryBridge API](docs/BatteryBridge.md) (英文).
- 您还可以在偏好设置中将状态栏图标更改为实时电量显示, 就像系统自带图标的那样.  
- 在设备胶囊上将其固定, 即可为它单独生成一个常驻的状态栏图标.  
- 如有需要, 可以将某些设备从面板中隐藏, 亦可随时在偏好设置 → *屏蔽设备*中解除隐藏.  

## 常见问题
**1. 为什么我的 iPhone / iPad / Apple Watch 没有显示出来?**  
> 请确保 iPhone / iPad 已信任此 Mac ***(且至少在 GlassyBattery 运行状态下使用数据线连接 Mac 一次以进行配对)***. 之后只需确保其与 Mac 处于同一局域网中即可.  

**2. 我的 Apple Watch 也需要进行预连接吗?**  
> 不需要, 一旦 GlassyBattery 通过 WiFi 或 USB 发现任何已配对的 iPhone, 将会自动读取与其配对的 Apple Watch 的电量信息 **(通过蓝牙发现的 iPhone 不支持读取手表电量!)**

**3. 为什么某些设备名称前有一个⚠️符号?**
> 出现这个符号, 说明此设备已经超过十分钟以上没有更新过电量信息, 可能已离线或关闭.

**4. 我的 iPhone 没有连接到 WiFi, 可以读取电池信息吗?**  
> 在设置面板中启用 `通过蓝牙发现 iPhone / iPad` 选项, 并保持设备蓝牙开启即可 ***(此功能仅支持 iPhone 或插卡版 iPad设备!)***  

**5. 为什么 GlassyBattery 需要使用蓝牙权限?**  
> GlassyBattery 需要使用蓝牙来获取周边设备的数据包以解析其电量信息.  

**6. 为什么我的面板看起来是扁平的 / 为什么没有玻璃效果?**  
> Liquid Glass 是 macOS 26 的材质. 在 macOS 13–15 上, 同样的面板与小组件会以带色调的半透明填充呈现.  

**7. 面板在我的壁纸上不太清晰, 可以调整吗?**  
> 偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown* → *Theme*. **自适应**会跟随面板背后的桌面; **跟随系统**、**浅色**与**深色**则固定为指定外观. 该设置将在下次打开面板时生效.  

**8. 工具栏表盘背后的 W 和 % 我不喜欢, 能改吗?**
> 偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown* → *Dial Unit*, 可在**水印**、**角标**与**隐藏**之间选择. 选择器下方有表盘的实时预览.  

**9. 面板在我的显示器上太小 (或太大), 可以调整尺寸吗?**
> 偏好设置 → *菜单栏 & 程序坞* → *Device Dropdown* → *Panel Size*, 可在**小**、**默认**与**大**之间选择. 整块面板会按比例缩放, 该设置将在下次打开面板时生效.  

## 致谢
[libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) @libimobiledevice  
> GlassyBattery 使用基于`73b6fd1`版本编译的 libimobiledevice 可执行文件及运行库. 如有疑虑可自行编译替换  

[comptest](https://gist.github.com/nikias/ebc6e975dc908f3741af0f789c5b1088) @nikias  
> GlassyBattery 使用基于此源代码编译的 comptest 可执行文件. 如有疑虑可自行编译替换  

[MultipeerKit](https://github.com/insidegui/MultipeerKit) @insidegui  
> GlassyBattery 使用 MultipeerKit 框架来进行局域网内的对称多端通信   

[ChatGPT](https://chat.openai.com) @OpenAI  
> 注: 本项目部分代码使用 ChatGPT 生成或重构整理

## 关于本分支
GlassyBattery 基于 [lihaoyun6](https://github.com/lihaoyun6) 的 [AirBattery](https://github.com/lihaoyun6/AirBattery) 修改而来, 由 Xiding Luo 于 2026 年围绕 Liquid Glass 界面进行了重新设计与更名. 原版应用、设备发现引擎与 Nearcast 功能均归功于原作者. 如果你喜欢它, 欢迎支持[上游项目](https://github.com/lihaoyun6/AirBattery).

GlassyBattery 使用独立的 Bundle ID (`com.deckirin.GlassyBattery`), 因此可以与 AirBattery 同时安装, 其设置、小组件与 `glassybattery` 命令均与 AirBattery 相互独立.

## 许可协议
GlassyBattery 与 AirBattery 一样, 是以 [GNU Affero 通用公共许可证 v3.0](./LICENSE) 发布的自由软件. 原作品版权所有 © 2024 lihaoyun6; 修改部分版权所有 © 2026 Xiding Luo. 本软件不提供任何担保.
