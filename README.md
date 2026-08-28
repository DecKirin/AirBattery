# 
<p align="center">
<img src="./AirBattery/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="200" height="200" />
<h1 align="center">AirBattery</h1>
<h3 align="center">Every battery around your Mac, in one Liquid Glass panel — plus the Dock, the status bar, and widgets.<br><a href="./README_zh.md">[中文版本]</a><br><a href="https://lihaoyun6.github.io/airbattery/">[Landing Page]</a></h3> 
</p>

AirBattery finds the battery level of your Mac and of every Apple or Bluetooth device near it — iPhone, iPad, Apple Watch, AirPods, Magic Mouse / Keyboard / Trackpad, third-party BT peripherals — with no pairing dance and no configuration. It shows them wherever you want to look: a floating glass panel under the Dock or status bar icon, a live battery icon in the menu bar, widgets on the desktop and in Notification Centre, or the `airbattery` command in your terminal.

## Screenshots
<p align="center">
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./img/preview_dark.png">
  <source media="(prefers-color-scheme: light)" srcset="./img/preview.png">
  <img alt="AirBattery Screenshots" src="./img/preview.png" width="840"/>
</picture>
</p>

## The dropdown panel

Clicking the Dock or status bar icon opens a borderless panel that floats directly over your desktop — there is no window chrome behind it, only the elements themselves.

- **Device capsules.** Each device is a translucent capsule whose fill runs proportionally to its charge and takes the colour of its battery tier — green, yellow, red. An icon-and-percentage badge rides on the top edge, and the name sits on the fill with the model underneath.
- **Charge state as a bolt.** Your Mac's own capsule shows a ⚡ before the remaining time while charging, a bare duration while discharging, and ⚡ *Fully Charged* once it is done.
- **Hover actions.** Point at a capsule and its subtitle turns into a row of buttons: set a battery alert, pin the device to its own status bar item, copy its name, or hide it from the list.
- **Toolbar dials.** A floating row of glass buttons sits above the grid — Settings, a power dial, a battery health ring, and Quit.
  - The **power dial** reports the adapter's negotiated wattage against a 140 W ceiling while plugged in, and what the machine is currently drawing while on battery.
  - The **health ring** shows your Mac battery's remaining capacity as a percentage.

  Both appear only when the machine has a battery and IOKit has a reading to give, so desktop Macs simply see fewer buttons.
  - **Dial units.** Preferences → *Menu Bar & Dock* → *Device Dropdown* → *Dial Unit* chooses how those two dials label their unit (W, %): **Watermark** (the default) sets it behind the number as a faint glyph, **Badge** moves it into a small glass circle straddling the dial's lower-right edge, and **Hidden** leaves the number bare.
- **Themes.** Preferences → *Menu Bar & Dock* → *Device Dropdown* picks how the glass resolves: **Adaptive** (the default) samples whatever is behind the panel so it stays readable on any wallpaper, while **System**, **Light** and **Dark** pin an appearance.
- **Panel size.** Preferences → *Menu Bar & Dock* → *Device Dropdown* → *Panel Size* scales the panel proportionally — width, capsules, dials and type all move together — between **Small**, **Default** and **Large**.

On macOS 26 all of this is drawn in real Liquid Glass, including the widgets, which let the system material show through instead of painting over it. On macOS 13–15 the same layout renders with tinted translucent fills.

## Installation and Usage
### System Requirements:
- macOS 13.0 and later (Liquid Glass materials require macOS 26)

### Installation:
Download the latest installation file [here](../../releases/latest) or install via Homebrew:  

```bash
brew install lihaoyun6/tap/airbattery
```

### Usage: 
- After AirBattery is started, it will be displayed on both the Dock and the status bar by default, or only one of them (can be configured)  

- AirBattery will automatically search for all devices supported by the **"Nearbility Engine"** without manual configuration.  
- Click the Dock icon / status bar icon, or add a widget to view the battery usage of your devices.  
- You can also use the **"Nearcast"** feature to check the battery usage of other Macs and their peripherals in the LAN at any time.  
- You can also change the status bar icon to a real-time battery icon in preferences, just like the one that comes with the system.  
- Pin a device from its capsule to give it a permanent status bar item of its own.  
- If necessary, you can hide certain devices from the panel, and unhide them at any time in Preferences → *Blocklist*.  

## Q&A
**1. Why is my iPhone / iPad / Apple Watch not showing up?**
> Please make sure the iPhone / iPad has trusted this Mac ***(and connected the Mac with a data cable at least once while AirBattery is running to pair)***. Then just make sure it is on the same LAN as the Mac.  

**2. Does my Apple Watch need to be pre-connected?**
> No, when AirBattery detects a paired iPhone via WiFi or USB, it will automatically read the battery data of the Apple Watch paired with it **(iPhone discovered via Bluetooth does not support reading the watch battery!)** 

**3. Why do some device name have a ⚠️ symbol?**
> If this symbol appears, it means that the device has not updated its battery information for more than ten minutes, and may be offline or turned off.  

**4. My iPhone is not connected to WiFi, can I get the battery info?**
> Please install AirBattery v1.1.2 or higher, enable the **`iPhone / iPad(Cellular) over BT`** in the preferences, and keep the device's Bluetooth turned on ***(Only supports iPhone or cellular iPad!)***  

**5. Why does AirBattery need Bluetooth permission?**
> AirBattery needs Bluetooth to capture packets from peripheral devices in order to parse their battery information.  

**6. Why does the panel look flat / why don't I see the glass?**
> Liquid Glass is a macOS 26 material. On macOS 13–15 the same panel and widgets render with tinted translucent fills instead.  

**7. The panel is hard to read over my wallpaper. Can I fix it?**
> Preferences → *Menu Bar & Dock* → *Device Dropdown* → *Theme*. **Adaptive** tracks the desktop behind the panel; **System**, **Light** and **Dark** pin an appearance instead. The change takes effect the next time the dropdown is opened.  

**8. The W and % behind the toolbar dials bother me. Can I change them?**
> Preferences → *Menu Bar & Dock* → *Device Dropdown* → *Dial Unit*, which offers **Watermark**, **Badge** and **Hidden**. A live preview of the dials sits under the picker.  

**9. The panel is too small (or too large) on my display. Can I resize it?**
> Preferences → *Menu Bar & Dock* → *Device Dropdown* → *Panel Size*, which offers **Small**, **Default** and **Large**. The whole panel scales proportionally, and the change takes effect the next time the dropdown is opened.  

## Donate
<img src="./img/donate.png" width="350"/>

## Thanks
[libimobiledevice](https://github.com/libimobiledevice/libimobiledevice) @libimobiledevice  
> AirBattery uses executable files and runtime libraries compiled from libimobiledevice based on version `73b6fd1`. Feel free to compile and replace them if in doubt.

[comptest](https://gist.github.com/nikias/ebc6e975dc908f3741af0f789c5b1088) @nikias  
> AirBattery uses executable files compiled based on this source code. Feel free to compile and replace them if in doubt.  

[MultipeerKit](https://github.com/insidegui/MultipeerKit) @insidegui  
> AirBattery uses MultipeerKit for symmetric multi-end communication within the LAN  

[ChatGPT](https://chat.openai.com) @OpenAI  
> Some of the code in this project is generated or refactored by ChatGPT.  
