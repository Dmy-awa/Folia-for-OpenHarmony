# HarmonyOS NEXT 窗口 / 强制横屏 / 多设备 / 自适应布局 实现速查

> 本文是从本地已下载的 OpenHarmony 官方 markdown 文档中**逐字摘录 + 归纳**得到的唯一参考文件，用于编写「手机 / 平板 / 鸿蒙电脑(PC/2in1) 上强制横屏运行的 ArkTS 音乐播放器」的应用配置与外壳（shell）。
>
> **⚠️ 来源与基线约束（务必先读）**
> 1. 本文只覆盖本地 `_docs\` 下的 OpenHarmony 官方文档，以及按同样命名规则新下载的 OpenHarmony `docs` 仓库（`master` 分支）页面。**没有**访问 developer.huawei.com（HarmonyOS 商业版文档）的能力。
> 2. **本地/新下载文档取自 OpenHarmony `master`，其中部分页面已演进到 API 20 / API 23 / API 26。目标平台是 HarmonyOS NEXT API 14/15。** 因此凡带 `API n+` 上标且 `n > 15` 的能力，本文一律标注 **⚠️ 不可用于 API 14/15**。
> 3. 文档未明确写到的东西一律标注 **⚠️**，不臆造 API。
> 4. 本文件是**唯一**的窗口/配置/自适应布局参考；凡本文未列出的接口，视为「文档无证据」。

---

## 目录

1. [强制横屏](#1-强制横屏)
2. [loadContent 与全屏 / 沉浸式 / 常亮](#2-loadcontent-与全屏--沉浸式--常亮)
3. [module.json5 的 deviceTypes 全量取值](#3-modulejson5-的-devicetypes-全量取值)
4. [module.json5 完整要点与实例](#4-modulejson5-完整要点与实例)
5. [app.json5 要点与实例](#5-appjson5-要点与实例)
6. [ArkUI 自适应布局（手机 / 平板 / PC / 2in1）](#6-arkui-自适应布局手机--平板--pc--2in1)
7. [安全区、刘海 / 挖孔、避免拉伸](#7-安全区刘海--挖孔避免拉伸)
8. [推荐的整体策略](#8-推荐的整体策略)

---

## 1. 强制横屏

### 1.1 唯一正确的接口：`setPreferredOrientation`

**结论：在 HarmonyOS / OpenHarmony 的 Window 模块里，强制横屏的接口只有 `setPreferredOrientation()`，不存在 `window.setOrientation()`。**

`arkts-apis-window-Window.md` 中 `setPreferredOrientation` 有两个重载（均为 **API 9+**）：

```ts
// 重载 1：AsyncCallback
setPreferredOrientation(orientation: Orientation, callback: AsyncCallback<void>): void

// 重载 2：Promise
setPreferredOrientation(orientation: Orientation): Promise<void>
```

文档原文（两个重载的说明一致）：

> 设置主窗口的显示方向属性……**非主窗口调用后不生效不报错。**

**系统能力：** `SystemCapability.WindowManager.WindowManager.Core`
**原子化服务 API：** 从 API version 11 开始支持。

**设备行为差异**（文档原文，逐条照抄）：

> - 设备支持 sensor 旋转且未处于自由窗口状态：立即生效。
> - 设备支持 sensor 旋转且处于自由窗口状态：调用不生效不报错，切换到非自由窗口状态后生效。
> - 其他情况：不生效不报错。

**错误码：**

| 错误码 ID | 错误信息 |
| --- | --- |
| 401 | Parameter error. Possible cause: Invalid parameter value range. |
| 1300002 | This window state is abnormal. Possible cause: 1. The window is not created or destroyed; 2. Internal task error. |

#### 命名差异：`setPreferredOrientation` vs `setOrientation`

| 你可能会看到的写法 | 文档结论 |
| --- | --- |
| `windowClass.setPreferredOrientation(...)` | ✅ **正确**。Window 模块的正式接口，API 9 起就叫这个名字，14/15 也是这个名字。 |
| `windowClass.setOrientation(...)` | ❌ **不存在**。`arkts-apis-window-Window.md`（13k+ 行）全文没有 `setOrientation`。⚠️ 官方 FAQ (`window-faqs.md`) 里出现的 `setOrientation(orientation: number)` 是**示例自己定义的私有辅助方法名**，它内部调用的仍然是 `setPreferredOrientation`。不要照抄成 API。 |
| `featureAbility.getContext().setDisplayOrientation(0/1)` | ⚠️ **仅 FA 模型遗留**，只出现在 `arkts-layout-development-media-query.md` 的旧示例中。Stage 模型下不使用。 |
| `windowClass.setPreferredOrientationWithResult(orientation)` | ⚠️ **API 26.0.0**，目标 API 14/15 **不可用**。 |
| `windowClass.getPreferredOrientation()` | ✅ API 12+，可用于读回当前旋转策略；未指定方向时返回 `window.Orientation.UNSPECIFIED`。API 14/15 可用。 |

### 1.2 `window.Orientation` 枚举全表（共 18 个取值）

来源：`arkts-apis-window-e.md#orientation9` 与 `window-rotation.md#旋转策略及设备差异性`（两处取值一致）。**注意：这是「窗口旋转策略」的枚举，与 `display.Orientation`（屏幕方向）不是同一个概念，取值定义也不同。**

#### 固定方向类型（4 个）

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `PORTRAIT` | 1 | 表示竖屏显示模式。 |
| `LANDSCAPE` | **2** | 表示横屏显示模式。 |
| `PORTRAIT_INVERTED` | 3 | 表示反向竖屏显示模式。 |
| `LANDSCAPE_INVERTED` | 4 | 表示反向横屏显示模式。 |

> 这 4 种方向类型通常用于设置应用固定在设备的一个方向显示，如游戏类应用。**不论用户如何握持设备，应用的显示方向均不会变化。**

#### 自动旋转方向类型（7 个）

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `AUTO_ROTATION` | 5 | 跟随传感器自动旋转，可以旋转到竖屏、横屏、反向竖屏、反向横屏四个方向，且不受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_PORTRAIT` | 6 | 跟随传感器自动竖向旋转，可以旋转到竖屏、反向竖屏，无法旋转到横屏、反向横屏，且不受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_LANDSCAPE` | 7 | 跟随传感器自动横向旋转，可以旋转到横屏、反向横屏，无法旋转到竖屏、反向竖屏，且不受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_RESTRICTED` | 8 | 跟随传感器自动旋转，可以旋转到竖屏、横屏、反向竖屏、反向横屏四个方向，且受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_PORTRAIT_RESTRICTED` | 9 | 跟随传感器自动竖向旋转，可以旋转到竖屏、反向竖屏，无法旋转到横屏、反向横屏，且受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_LANDSCAPE_RESTRICTED` | 10 | 跟随传感器自动横向旋转，可以旋转到横屏、反向横屏，无法旋转到竖屏、反向竖屏，且受控制中心的旋转开关控制。 |
| `AUTO_ROTATION_UNSPECIFIED` | 12 | 跟随传感器自动旋转，受控制中心的旋转开关控制，且可旋转方向受系统判定（如在某种设备，可以旋转到竖屏、横屏、反向横屏三个方向，无法旋转到反向竖屏）。 |

#### 临时方向类型（4 个）

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `USER_ROTATION_PORTRAIT` | 13 | 调用时临时旋转到竖屏，之后跟随传感器自动旋转，受控制中心的旋转开关控制，且可旋转方向受系统判定。 |
| `USER_ROTATION_LANDSCAPE` | 14 | 调用时临时旋转到横屏，之后跟随传感器自动旋转，受控制中心的旋转开关控制，且可旋转方向受系统判定。 |
| `USER_ROTATION_PORTRAIT_INVERTED` | 15 | 调用时临时旋转到反向竖屏，之后跟随传感器自动旋转，受控制中心的旋转开关控制，且可旋转方向受系统判定。 |
| `USER_ROTATION_LANDSCAPE_INVERTED` | 16 | 调用时临时旋转到反向横屏，之后跟随传感器自动旋转，受控制中心的旋转开关控制，且可旋转方向受系统判定。 |

> 这 4 种方向类型通常用于视频类应用在小窗播放进入全屏播放时使用。

#### 其他方向类型（3 个）

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `UNSPECIFIED` | 0 | 表示未定义方向模式，由系统判定。 |
| `LOCKED` | 11 | 表示锁定模式，窗口显示方向与屏幕当前方向一致。 |
| `FOLLOW_DESKTOP` | 17 | 表示跟随桌面的旋转模式，如果桌面可以旋转则可旋转，桌面不可旋转则不可旋转。 |

> - `UNSPECIFIED` 是未定义方向类型，即当应用既没有在 `model.json5`（注：文档此处笔误，实为 `module.json5`）设置，也没有在运行时调用 `setPreferredOrientation()` 设置时，系统默认应用使用该类型。此时，应用的显示方向由系统判定。通常直板机上默认竖屏显示且不支持旋转；平板上支持旋转到四个方向，且受控制中心系统旋转锁定开关控制。
> - `LOCKED` 通常用于应用拉起应用场景。⚠️ `window-faqs.md` 明确写：**「不建议使用 LOCKED，可能会发生非预期的方向改变」**。
> - `FOLLOW_DESKTOP` 通常直板机桌面固定竖屏显示不可旋转，平板桌面可以旋转。而折叠机比较特别，在折叠态时桌面与直板机一样不可旋转，但是在展开态时与平板规格一样可以旋转。

#### ⚠️ 音乐播放器该用哪个

**用 `window.Orientation.LANDSCAPE`（固定值 2），不要用 `AUTO_ROTATION_LANDSCAPE`，也不要用 `LOCKED`。**
理由（全部来自文档原文）：`LANDSCAPE` 属于固定方向类型，「不论用户如何握持设备，应用的显示方向均不会变化」；`LOCKED` 被 FAQ 点名「不建议使用」；`AUTO_ROTATION_*` 系列是「跟随传感器自动旋转」，不保证恒为横屏。

### 1.3 去哪里调用：`EntryAbility.onWindowStageCreate`

**取主窗口的两种写法**（都来自文档）：

```ts
// 写法 A：同步（getMainWindowSync，API 9+）
windowStage.getMainWindowSync(): Window
```
> `getMainWindowSync` 文档原文：「获取该 WindowStage 实例下的主窗口，该接口为同步调用。**调用该接口前，建议先通过 `loadContent` 方法或者 `setUIContent` 方法完成页面加载。**」
> 错误码：`1300002`（window 未创建/已销毁）、`1300005`（window stage 异常）。

```ts
// 写法 B：异步回调（getMainWindow，API 9+）
windowStage.getMainWindow(callback: AsyncCallback<Window>): void
```

**⚠️ 重要时序冲突（文档内部不一致，必须知道）：**

- `setPreferredOrientation` 的官方示例是在 `onWindowStageCreate` 里用 `getMainWindow()` **回调中、`loadContent` 之前**设置方向。
- `getMainWindowSync` 的文档却「建议先 loadContent 再取主窗口」。

**因此推荐写法：在 `onWindowStageCreate` 里用 `getMainWindow(cb)` 回调设置方向并调用 `loadContent`（官方示例路径），或先 `loadContent` 再 `getMainWindowSync()` 设置方向（遵循同步接口建议）。两者文档均有出处，实测优先用写法 A/B 的官方示例组合。**

```ts
// EntryAbility.ets —— 官方示例路径（getMainWindow 回调内设置方向）
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  onWindowStageCreate(windowStage: window.WindowStage): void {
    let windowClass: window.Window | undefined = undefined;
    windowStage.getMainWindow((err: BusinessError, data) => {
      const errCode: number = err.code;
      if (errCode) {
        console.error(`Failed to obtain the main window. Cause code: ${err.code}, message: ${err.message}`);
        return;
      }
      windowClass = data;
      // 强制横屏
      try {
        windowClass.setPreferredOrientation(window.Orientation.LANDSCAPE)
          .then(() => { console.info('Succeeded in setting window orientation.'); })
          .catch((err: BusinessError) => {
            console.error(`Failed to set window orientation. Cause code: ${err.code}, message: ${err.message}`);
          });
      } catch (exception) {
        console.error(`Failed. Cause code: ${exception.code}, message: ${exception.message}`);
      }
    });

    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        console.error('Failed to load the content. Cause:' + JSON.stringify(err));
        return;
      }
      console.info('Succeeded in loading the content.');
    });
  }
}
```

**另一种等价取窗方式（`window-faqs.md` 示例，Stage 模型下从 UIContext 拿）：**

```ts
private context = this.getUIContext().getHostContext() as common.UIAbilityContext;
private windowClass = (this.context as common.UIAbilityContext).windowStage.getMainWindowSync();
// 之后：this.windowClass.setPreferredOrientation(orientation)
```

### 1.4 在 2in1 / 鸿蒙电脑（PC）上会怎样

文档**没有**一句「2in1 上 setPreferredOrientation 会 XXX」的专门表述。但把以下几段原文拼起来，结论是确定的：

1. **2in1 设备上的窗口默认为自由窗口**（`window-terminology.md` 原文）：
   > **2in1 设备**：2in1 设备上的窗口，默认为自由窗口。

2. **`setPreferredOrientation` 的设备行为差异**（原文，见 §1.1）：
   > - 设备支持 sensor 旋转且处于自由窗口状态：**调用不生效不报错，切换到非自由窗口状态后生效**。
   > - 其他情况：**不生效不报错**。

3. **`window-rotation.md` 对「特殊场景」的原文**：
   > 特殊情况下，比如悬浮窗、分屏、多任务、应用后台、自由多窗等场景，应用设置旋转策略后，**系统忽略此旋转策略，接口可正常调用，但应用显示方向并不会改变**。仅当应用退出这些场景时，系统才根据应用设置的旋转策略，重新调整应用的显示布局。
   >
   > - 场景 1：在分屏、悬浮窗等特殊的场景，系统为了保持显示效果，会强制应用按照竖屏方向布局显示。此时，若应用改变旋转策略为「LANDSCAPE」，应用显示方向不会变化。
   > - 场景 2：**在自由多窗模式下，应用都会被强制成小窗显示。此时，若应用修改旋转策略，均不会触发旋转。**

4. **无 sensor 设备**：
   > 此外，应用的显示方向跟 sensor 强相关，在无 sensor 的设备上，设置旋转策略同样不会生效。比如：TV 等设备没有 sensor，可正常调用 `setPreferredOrientation()` 接口，但实际应用方向不会变化。

**⚠️ 结论（推断，非文档原句）：** 在 2in1 / 鸿蒙电脑上，应用窗口默认处于自由窗口状态，`setPreferredOrientation(LANDSCAPE)` **会正常返回但不一定生效（不报错）**；PC 也通常没有重力 sensor。所以 **PC/2in1 不能被「强制横屏」锁死，必须把横屏当成「内容策略」而不是「窗口策略」来设计**（见 §8）。

**旁证：** `on('rotationChange')`（API 19+）的设备行为差异原文明确把 PC/2in1 单列：
> 针对 PC/2in1 设备：在 API version 23 之前，调用该接口会返回 801 错误码；从 API version 23 开始，可正常调用该接口且立即生效。

⚠️ 即：**PC/2in1 在 API 14/15 上连「旋转事件监听」能力都不具备**（801 = Capability not supported）。这进一步说明 PC 上没有「手机式旋转」语义。

---

## 2. loadContent 与全屏 / 沉浸式 / 常亮

### 2.1 `windowStage.loadContent` 完整签名（3 个重载，均 API 9+）

```ts
// 重载 1：带 LocalStorage + callback
loadContent(path: string, storage: LocalStorage, callback: AsyncCallback<void>): void

// 重载 2：带可选 LocalStorage，Promise
loadContent(path: string, storage?: LocalStorage): Promise<void>

// 重载 3：仅 callback
loadContent(path: string, callback: AsyncCallback<void>): void
```

**参数表（原文）：**

| 参数名 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `path` | string | 是 | 要加载到窗口中的页面内容的路径，**该路径需添加到工程的 `main_pages.json` 文件中。不支持相对路径写法，需与 `main_pages.json` 中的 `src` 取值保持一致。** |
| `storage` | `LocalStorage` | 重载 1 必填 / 重载 2 可选（默认为空） | 页面级 UI 状态存储单元，为加载到窗口的页面内容传递状态属性。 |
| `callback` | `AsyncCallback<void>` | 是 | 回调函数。 |

**文档原文说明：**
> 建议在 UIAbility 启动过程中调用该接口，**重复调用将首先销毁旧的页面内容（即 UIContent）再加载新页面内容，请谨慎使用。当前 UI 的执行上下文可能不明确，所以不建议在回调函数中做 UI 相关的操作。**

**错误码：** `401`、`1300002`（This window state is abnormal. Possible cause: The window is not created or destroyed.）

**带 LocalStorage 的官方示例（音乐播放器把 `windowStage` 或全局状态塞进去的推荐做法）：**

```ts
import { UIAbility } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';

export default class EntryAbility extends UIAbility {
  storage: LocalStorage = new LocalStorage();

  onWindowStageCreate(windowStage: window.WindowStage) {
    this.storage.setOrCreate('storageSimpleProp', 121);
    try {
      windowStage.loadContent('pages/page2', this.storage, (err: BusinessError) => {
        if (err.code) {
          console.error(`Failed to load the content. Cause code: ${err.code}, message: ${err.message}`);
          return;
        }
        console.info('Succeeded in loading the content.');
      });
    } catch (exception) {
      console.error(`Failed to load the content. Cause code: ${exception.code}, message: ${exception.message}`);
    }
  }
}
```

> 文档另一处示例把 `windowStage` 本身通过 `AppStorage.setOrCreate('windowStage', windowStage)` 传给页面，页面里再 `AppStorage.get('windowStage')` 取回（见 `application-window-stage.md`）。

### 2.2 全屏 / 沉浸式

#### `setWindowLayoutFullScreen`（API 9+）

```ts
setWindowLayoutFullScreen(isLayoutFullScreen: boolean): Promise<void>
```

原文：
> 设置应用主窗口或应用子窗口的布局是否为沉浸式布局，使用 Promise 异步回调。**其余窗口调用不生效也不报错。**
> **沉浸式布局生效时，布局不避让状态栏与三键导航栏，组件可能产生与其重叠的情况。**
> 非沉浸式布局生效时，布局避让状态栏与三键导航栏，组件不会与其重叠。
> 参数：`isLayoutFullScreen` — 窗口的布局是否为沉浸式布局（**该沉浸式布局状态栏、三键导航栏仍然显示**）。true 表示沉浸式布局；false 表示非沉浸式布局。

**设备行为差异（原文）：**
> 在 OpenHarmony 5.0.2 之前，该接口在所有设备中可正常调用。
> 从 OpenHarmony 5.0.2 开始，该接口在支持并处于自由窗口状态的设备上**调用不生效也不报错**，切换到非自由窗口状态时生效；在支持但不处于自由窗口状态的设备及不支持自由窗口状态的设备上可正常调用。

⚠️ **5.0.2 ≈ API 14 时代**，所以这条差异对 API 14/15 直接适用：**PC/2in1（默认自由窗口）上 `setWindowLayoutFullScreen` 很可能不生效**。

**错误码：** `401`、`1300002`、`1300003`。

#### `setWindowSystemBarEnable`（API 9+）

```ts
setWindowSystemBarEnable(names: Array<'status' | 'navigation'>): Promise<void>
```

原文：
> 设置主窗口状态栏、三键导航栏的可见模式，状态栏通过 `status` 控制、三键导航栏通过 `navigation` 控制，使用 Promise 异步回调。
> **调用生效后返回并不表示状态栏、三键导航栏的显示或隐藏已完成。主窗口在非全屏/最大化模式（悬浮窗、分屏等场景）下配置不生效，进入全屏/最大化模式后配置生效。**

参数表原文：
> `names`：设置窗口全屏/最大化模式时状态栏、三键导航栏是否显示。例如，需全部显示，该参数设置为 `['status', 'navigation']`；设置为 `[]`，则不显示。

**设备行为差异（原文）：**
> 在 OpenHarmony 5.0.0 之前，该接口在所有设备中可正常调用。
> 从 OpenHarmony 5.0.0 开始，该接口在支持并处于自由窗口状态的设备上调用不生效也不报错；在支持但不处于自由窗口状态的设备及不支持自由窗口状态的设备上可正常调用。

#### `setWindowSystemBarProperties`（API 9+）

用于把状态栏 / 导航栏调成与主窗口协调（沉浸式的「方式二」）：

```ts
setWindowSystemBarProperties(systemBarProperties: SystemBarProperties): Promise<void>
```

官方示例用到字段：
```ts
let sysBarProps: window.SystemBarProperties = {
  statusBarColor: '#ff00ff',
  navigationBarColor: '#00ff00',
  // 以下两个属性从 API Version 8 开始支持
  statusBarContentColor: '#ffffff',
  navigationBarContentColor: '#ffffff'
};
```

#### `setImmersiveModeEnabledState`（API 12+，可用于 API 14/15）

```ts
setImmersiveModeEnabledState(enabled: boolean): void
```
原文：
> 设置当前窗口是否开启沉浸式布局，**该调用不会改变窗口模式和窗口大小**。仅主窗口和子窗口可调用。
> 从 OpenHarmony 5.0.2 开始，该接口在支持并处于自由窗口状态的设备上调用不生效也不报错；在支持但不处于自由窗口状态的设备及不支持自由窗口状态的设备上可正常调用。

#### 沉浸式的官方两种做法（`application-window-stage.md` 原文）

> - 方式一：应用主窗口为全屏窗口时，调用 `setWindowSystemBarEnable` 接口，设置导航栏、状态栏不显示，从而达到沉浸式效果。
> - 方式二：调用 `setWindowLayoutFullScreen` 接口，设置应用主窗口为全屏布局；然后调用 `setWindowSystemBarProperties` 接口，设置导航栏、状态栏的透明度、背景/文字颜色以及高亮图标等属性，使之保持与主窗口显示协调一致，从而达到沉浸式效果。

> **⚠️ 页面级限制（原文）：** 当前沉浸式界面开发**仅支持窗口级别的配置，暂不支持 Page 级别的配置**。若有 Page 级别切换的需要，可以在页面生命周期开始，例如 `onPageShow` 中设置沉浸模式，然后在页面退出，例如 `onPageHide` 中恢复默认设置来实现。
>
> **⚠️ 生效前提（原文）：** 沉浸式能力**只在应用主窗口作为全屏窗口时生效**。通常情况下，应用的辅助窗口（子窗、全局悬浮窗等）和**处于自由窗口下的应用主窗口无法使用沉浸式能力**。

#### 组合示例（音乐播放器推荐写法）

```ts
// EntryAbility.ets (onWindowStageCreate 内)
let windowClass = windowStage.getMainWindowSync();

// 1) 强制横屏策略（PC/2in1 上可能不生效，见 §1.4）
windowClass.setPreferredOrientation(window.Orientation.LANDSCAPE);

// 2) 沉浸式布局（不避让状态栏/导航栏，组件可能与其重叠）
windowClass.setWindowLayoutFullScreen(true).catch((err: BusinessError) => { /* ... */ });

// 3) 隐藏状态栏 + 三键导航栏（仅全屏/最大化模式下生效）
windowClass.setWindowSystemBarEnable([]).catch((err: BusinessError) => { /* ... */ });

// 4) 播放页常亮
windowClass.setWindowKeepScreenOn(true).catch((err: BusinessError) => { /* ... */ });
```

### 2.3 屏幕常亮 `setWindowKeepScreenOn`（API 9+）

```ts
setWindowKeepScreenOn(isKeepScreenOn: boolean): Promise<void>          // 重载 1
setWindowKeepScreenOn(isKeepScreenOn: boolean, callback: AsyncCallback<void>): void  // 重载 2
```

原文（**这段对音乐播放器很重要，是文档明确的使用约束**）：
> 设置当前窗口位于前台时当前设备的屏幕是否为常亮状态，**异源虚拟屏下不生效**。
> **仅在必要场景（导航、视频播放、绘画、游戏等场景）下，设置该属性为 true；退出上述场景后，应当重置该属性为 false；其他场景（无屏幕互动、音频播放等）下，不使用该接口；系统检测到非规范使用该接口时，可能会恢复自动灭屏功能。**

**错误码：** `401`、`1300002`、`1300003`。

> **⚠️ 设计含义：** 纯音频后台播放**不应**用 `setWindowKeepScreenOn`（文档明确列「音频播放」为「不使用该接口」的场景）。只有**前台歌词页 / 横屏沉浸播放页**才开，离开该页面立即设回 `false`。

---

## 3. module.json5 的 deviceTypes 全量取值

### 3.1 官方表格（`module-configuration-file.md#devicetypes标签`，逐字照抄）

**表2** deviceTypes 标签说明：

| 设备类型 | 枚举值 | 说明 |
| --- | --- | --- |
| 平板 | `tablet` | - |
| 智慧屏 | `tv` | - |
| 智能手表 | `wearable` | 系统能力较丰富的手表，具备电话功能。 |
| 车机 | `car` | - |
| **PC/2in1** | **`2in1`** | **即 PC 设备，主要交互方式以多窗口、多任务及键盘鼠标操作为主，充分发挥设备的生产力属性。在 OpenHarmony 文档中，所有「2in1」均代表「PC/2in1」。** |
| 默认设备 | `default` | 默认设备类型，详情参考标准系统开发板。 |

> **⚠️ 关键结论（请直接采用）：鸿蒙电脑 / HarmonyOS PC 使用的 `deviceTypes` 值是 `"2in1"`，不是 `"pc"`。** 文档没有任何 `"pc"` 取值；文档明确写「在 OpenHarmony 文档中，所有"2in1"均代表"PC/2in1"」。

### 3.2 ⚠️ 关于 `phone`：表格里没有，但它是有效设备类型

**这是一个文档内部不一致点，必须清楚：**

- `module-configuration-file.md` 的 **deviceTypes 表格里没有 `phone`**（上表 6 项）。
- 但同一套文档中，`arkts-layout-development-media-query.md` 的媒体特征表 **明确把 `phone` 列为设备类型之一**：
  > `device-type` | 设备的类型。可选值：**default、phone、tablet、tv、car、wearable、2in1**。
- 且 `window-overview.md` 直接以 `phone` 作为设备名使用：
  > 针对不支持在 2in1 设备上运行的应用，或可同时支持在 **phone** 和 2in1 上运行的应用，窗口从前台进入后台状态，会驱动 UIAbility 为后台状态。
- `window-terminology.md` 也把 Phone 列为设备：
  > **Phone 设备**：部分 Phone 设备，支持开启自由多窗模式……

**⚠️ 结论：`module.deviceTypes` 在真实 HarmonyOS NEXT 设备上接受 `phone`（否则手机应用无法分发），但 OpenHarmony 官方 `module-configuration-file.md` 表格未列出它。本文把完整可用集合记为：**
```
phone / tablet / 2in1 / tv / wearable / car / default
```
**并在写作时把 `phone`、`2in1` 都写进去（例如 `["phone","tablet","2in1"]`）。**

### 3.3 其他相关枚举（FA 模型遗留，仅作辨析）

`module-structure.md`（FA 模型 `config.json` 文档）的 `deviceType` 多了 `liteWearable`（运动表）：

| 设备类型 | 枚举值 |
| --- | --- |
| 平板 | `tablet` |
| 智慧屏 | `tv` |
| 智能手表 | `wearable` |
| **运动表** | **`liteWearable`** |
| 车机 | `car` |
| 默认设备 | `default` |
| 2in1 | `2in1` |

> **⚠️ `liteWearable` 是 FA 模型 `config.json` 的 `deviceType` 取值，不要在 Stage 模型 `module.json5` 的 `deviceTypes` 里使用。**

### 3.4 ⚠️ 文档区分的「2in1」与「PC」

文档**不区分** `2in1` 与 `pc` 两个枚举值：只有 `2in1`。但在**文字描述**里经常写成「PC/2in1」「**PC/2in1 设备**」，这是同一个东西的中文/英文混写，不是两个设备类型。

### 3.5 顶层 `module.deviceTypes` 的约束

`module-configuration-file.md` 原文：
> `deviceTypes` | 标识当前 Module 可以运行在哪类设备上。**说明：当存在多个模块时，各模块的配置可以不同，但都必须包含将要安装的设备类型，以确保正常运行。** | 字符串数组 | **该标签不可缺省。**

用于覆盖设备类型的其他机制（原文）：`distributionFilter`（`screenShape` / `screenWindow` / `screenDensity` / `countryCode`，API 10+），仅用于「当一个工程中存在多个 Entry，且多个 Entry 配置的 deviceTypes 存在交集时」。

---

## 4. module.json5 完整要点与实例

配置文件位置：`工程名称/模块名称（例如 entry）/src/main/module.json5`
文档级说明原文：
> 配置文件中的示例代码直接拷贝到工程中可能编译不通过，请开发者根据需求进行配置。例如：通过 `$` 符号引用的资源文件如果工程中不存在，需要开发者手动添加或替换为实际的资源文件。
> **配置文件中，字段可以重复，以最后一个配置为准。**

### 4.1 顶层标签（只列与音乐播放器相关的）

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `name` | 标识当前 Module 的名称，确保该名称在整个应用中唯一。由字母、数字和下划线组成，且必须以字母开头；最大长度 128 字节。 | 字符串 | **不可缺省**。 |
| `type` | 当前 Module 的类型。取值：`entry`（应用的主模块）/ `feature`（动态特性模块）/ `har`（静态共享包）/ `shared`（动态共享包）。 | 字符串 | **不可缺省**。 |
| `description` | 当前 Module 的描述信息，长度不超过 255 字节，可以采用字符串资源索引格式。 | 字符串 | 可缺省，缺省值为空。 |
| `mainElement` | 当前 Module 的入口 UIAbility 名称，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `deviceTypes` | 见 §3。 | 字符串数组 | **不可缺省**。 |
| `deliveryWithInstall` | 是否随应用一起安装。true 跟随安装；false 不跟随。 | 布尔值 | Module 类型为 HAP 或 HSP 时**不可缺省**。 |
| `pages` | 标识 Module 的 profile 资源，用于列举每个页面信息，如 `"$profile:main_pages"`。 | 字符串 | 可缺省，缺省值为空。 |
| `metadata` | 自定义元信息。 | 对象数组 | 可缺省，缺省值为空。 |
| `abilities` | UIAbility 的配置信息。 | 对象数组 | 可缺省，缺省值为空。 |
| `extensionAbilities` | ExtensionAbility 的配置信息。 | 对象数组 | 可缺省，缺省值为空。 |
| `requestPermissions` | 运行时需向系统申请的权限集合。 | 对象数组 | 可缺省，缺省值为空。 |
| `backgroundModes`（在 ability 内） | 长时任务集合。 | 字符串数组 | 可缺省，缺省值为空。 |
| `routerMap` | 模块配置的路由表路径，`"$profile:router_map"`。 | 字符串 | 可缺省，缺省值为空。 |
| `isolationMode` | 多进程配置项。取值 `nonisolationFirst` / `isolationFirst` / `isolationOnly` / `nonisolationOnly`。**仅 2in1 和 tablet 设备支持将当前 Module 设置为独立进程。** | 字符串 | 可缺省，缺省值为 `nonisolationFirst`。 |

> ⚠️ `fileContextMenu` 标签：**仅在 PC/2in1 设备上生效；仅允许在 entry 类型模块中配置。**

### 4.2 `pages` 与 `window`（页面 + 设计基准宽度）

`pages` 指向 `/resources/base/profile/main_pages.json`：

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `src` | 所有页面的路由信息（页面路径和页面名称），以 `src/main/ets` 为基准。 | 字符串数组 | **不可缺省**。 |
| `window` | 与显示窗口相关的配置。 | 对象 | 可缺省，缺省值为空。 |

`window` 子标签：

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `designWidth` | 页面设计基准宽度。以此为基准，根据实际设备宽度来缩放元素大小。 | 数值 | 可缺省，缺省值为 720px。 |
| `autoDesignWidth` | 设计基准宽度是否自动计算。为 true 时 `designWidth` 被忽略，设计基准宽度由设备宽度与屏幕密度计算得出。 | 布尔值 | 可缺省，缺省值为 false。 |

### 4.3 `metadata` 标签（含窗口相关元数据）

通用三字段：

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `name` | 数据项的名称，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `value` | 数据项的值，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `resource` | 用户自定义数据的资源索引，例如 `$profile:shortcuts_config`。 | 字符串 | 可缺省，缺省值为空。 |

**窗口相关的官方 metadata 名（`window-config-m.md` 原文）：**

| name | value | 说明 / 生效范围 |
| --- | --- | --- |
| `ohos.ability.window.height` | 高度值（vp） | 主窗口的默认高度。 |
| `ohos.ability.window.width` | 宽度值（vp） | 主窗口的默认宽度。 |
| `ohos.ability.window.left` | `对齐方式 +/- 偏移量`（`center`/`left`/`right`，默认 `left`；偏移为 0 时可省略） | 主窗口默认左边的位置。 |
| `ohos.ability.window.top` | `对齐方式 +/- 偏移量`（`center`/`top`/`bottom`，默认 `top`） | 主窗口顶部的位置。 |
| `ohos.ability.window.isMaximize` | `true` / `false`（默认 false） | 主窗口启动时是否最大化。**该配置项仅在 PC/2in1 设备上生效**；且需要 `supportWindowMode` 配了 `fullscreen` 才生效。 |
| `enable.remove.starting.window` | `true` / `false`（未配置默认 false） | 配置 `removeStartingWindow`（API 14+）接口的启用状态。 |
| `ohos.ability.window.supportWindowModeInFreeMultiWindow` | `fullscreen,split,floating`（逗号分隔、无空格） | 自由多窗下可支持的窗口模式。**仅在支持并处于自由窗口状态的设备上生效。** |

> 优先级（原文）：自由多窗下可支持窗口模式配置优先级 = `SetSupportedWindowModes`（API 15+）> StartAbility 的 `StartOptions.SupportWindowMode` > metadata > `module.json5` 的 `abilities[].supportWindowMode`。
> 非自由多窗模式下**只能**通过 `abilities[].supportWindowMode` 配置，其他方式均不生效。
> 主窗显示设置优先级：全屏显示 > `startOptions` 指定大小和位置 > `setWindowRectAutoSave()`（API 14+） > metadata 配置最大化 > metadata 配置大小和位置。

### 4.4 `abilities[]` 标签（含 **`orientation`** —— 这就是「配置侧强制横屏」）

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `name` | UIAbility 组件的名称，长度不超过 127 字节，以字母开头，可含字母、数字、下划线或点号。 | 字符串 | **不可缺省**。 |
| `srcEntry` | UIAbility 的代码路径，长度不超过 127 字节，例如 `"./ets/entryability/EntryAbility.ets"`。 | 字符串 | **不可缺省**。 |
| `launchType` | 启动模式：`multiton` / `singleton` / `specified` / `standard`（multiton 曾用名）。 | 字符串 | 可缺省，缺省为 `singleton`。 |
| `description` | 描述信息，长度不超过 255 字节，建议用资源索引。 | 字符串 | 可缺省，缺省值为空。 |
| `icon` | 图标资源索引（分层图标见 `layered-image.md`）。 | 字符串 | 可缺省，缺省值为空。 |
| `label` | 对用户显示的名称，字符串资源索引，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `permissions` | 其他应用访问该 UIAbility 时需申请的权限。 | 字符串数组 | 可缺省，缺省值为空。 |
| `metadata` | UIAbility 的元信息，典型场景见窗口元数据配置。 | 对象数组 | 可缺省，缺省值为空。 |
| `exported` | 是否可以被其他应用拉起。true 可被拉起（入口 UIAbility 建议 true）；false 只能由同应用或具有 `ohos.permission.START_INVISIBLE_ABILITY` 权限的应用拉起。 | 布尔值 | 可缺省，缺省值为 `false`。 |
| `skills` | 能够接收的 Want 特征集。 | 对象数组 | 可缺省，缺省值为空。 |
| `backgroundModes` | 长时任务集合（音乐播放用 `audioPlayback`）。 | 字符串数组 | 可缺省，缺省值为空。 |
| **`orientation`** | **标识当前 UIAbility 组件启动时的方向。支持配置枚举，或启动方向资源索引。** | 字符串 | 可缺省，**缺省值为 `unspecified`**。 |
| `supportWindowMode` | 支持的窗口模式：`fullscreen` / `split` / `floating`。 | 字符串数组 | 可缺省，缺省值为 `["fullscreen","split","floating"]`。 |
| `preferMultiWindowOrientation` | 多窗布局方向，见下。 | 字符串 | 可缺省，缺省值为 `default`。 |
| `maxWindowRatio` / `minWindowRatio` | 支持的最大 / 最小宽高比，最小取值 0。 | 数值 | 可缺省，缺省为平台支持值。 |
| `maxWindowWidth` / `minWindowWidth` / `maxWindowHeight` / `minWindowHeight` | 支持的窗口宽 / 高范围，单位 **vp**。 | 数值 | 可缺省，缺省为平台支持值。 |
| `startWindow` | 启动页面 profile 资源。**如果配置了该标签，`startWindowIcon` 和 `startWindowBackground` 标签均不生效。**（API 20 起支持增强启动页） | 字符串 | 可缺省，缺省值为空。 |
| `startWindowIcon` | 启动页面图标资源索引。 | 字符串 | **不可缺省**。 |
| `startWindowBackground` | 启动页面背景颜色资源索引，示例 `$color:red`。 | 字符串 | **不可缺省**。 |
| `continuable` | 是否支持跨端迁移。 | 布尔值 | 可缺省，缺省值为 `false`。 |
| `removeMissionAfterTerminate` | 销毁后是否从任务列表移除。**2in1 设备和平板设备的自由多窗模式下配置不生效，默认移除任务。** | 布尔值 | 可缺省，缺省值为 `false`。 |
| `recoverable` | 故障后是否恢复原界面。 | 布尔值 | 可缺省，缺省值为 `false`。 |
| `isolationProcess` | 能否运行在独立进程。**仅 2in1 和 tablet 设备支持将 UIAbility 设置为独立进程。** | 布尔值 | 可缺省，缺省值为 `false`。 |
| `process` | 组件进程名。**仅在 PC/2in1 和 Tablet 设备上生效**；**从 API version 14 开始支持该标签**。 | 字符串 | 可缺省，缺省值为空。 |
| `continueType` / `continueBundleName` | 跨端迁移类型 / 其它应用名称列表（`continueBundleName` 从 API 13 开始支持）。 | 字符串数组 | 可缺省。 |

#### `orientation` 的完整合法取值（原文逐条）

| 取值 | 含义 |
| --- | --- |
| `unspecified` | 未指定方向，由系统自动判断显示方向。（**缺省值**） |
| `landscape` | 横屏。 |
| `portrait` | 竖屏。 |
| `follow_recent` | 跟随背景窗口的旋转模式。 |
| `landscape_inverted` | 反向横屏。 |
| `portrait_inverted` | 反向竖屏。 |
| `auto_rotation` | 随传感器旋转。 |
| `auto_rotation_landscape` | 传感器横屏旋转，包括横屏和反向横屏。 |
| `auto_rotation_portrait` | 传感器竖屏旋转，包括竖屏和反向竖屏。 |
| `auto_rotation_restricted` | 传感器开关打开，方向可随传感器旋转。 |
| `auto_rotation_landscape_restricted` | 传感器开关打开，方向可随传感器旋转为横屏，包括横屏和反向横屏。 |
| `auto_rotation_portrait_restricted` | 传感器开关打开，方向可随传感器旋转为竖屏，包括竖屏和反向竖屏。 |
| `locked` | 传感器开关关闭，方向锁定。 |
| `auto_rotation_unspecified` | 受开关控制和由系统判定的自动旋转模式。 |
| `follow_desktop` | 跟随桌面的旋转模式。 |

> **⚠️ 配置启动方向的资源索引时**，取值为长度不超过 255 字节的字符串，配置示例：`$string:orientation`。**从 API version 14 开始，支持配置启动方向资源索引。**

**⚠️ `orientation` 能否强制横屏？**
**能，但是「启动时方向」，不是「运行期锁定」。** 文档措辞是「标识当前 UIAbility 组件**启动时**的方向」。它和运行时 `setPreferredOrientation()` 共用同一套语义（`window-rotation.md` 原文：**「无论是哪种方式设置的 orientation 字段含义都一样，即旋转显示方向类型枚举（也叫旋转策略）。」**）。所以：
- 配置侧写 `"orientation": "landscape"` **等于**启动即调用 `setPreferredOrientation(LANDSCAPE)`；
- 但要「无论如何都保持横屏」，**仍必须**运行时调用 `setPreferredOrientation(window.Orientation.LANDSCAPE)`，因为配置项只管启动方向。

#### `preferMultiWindowOrientation` 完整取值（横向游戏/视频类应用关注）

| 取值 | 含义 |
| --- | --- |
| `default` | 缺省值，参数不配置默认值，建议其他应用类配置。 |
| `portrait` | 多窗布局方向为竖向，建议竖向游戏类应用配置。 |
| `landscape` | 多窗布局方向为横向，**配置后支持横屏悬浮窗和上下分屏**，建议横向游戏类应用配置。 |
| `landscape_auto` | 多窗布局动态可变为横向，需要配合 API `enableLandScapeMultiWindow` / `disableLandScapeMultiWindow` 使用，建议视频类应用配置。 |

> ⚠️ 两个 `enableLandScapeMultiWindow` / `disableLandScapeMultiWindow` 接口的文档原文约束：**此接口只对应用主窗口生效，且需要在 module.json5 配置文件中 abilities 标签中配置 `preferMultiWindowOrientation` 属性为 `"landscape_auto"`。**

### 4.5 `skills` 标签

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `actions` | 能够接收的 Action 值集合，通常为系统预定义 action。**一个 skill 中不建议配置多个 action，否则可能导致无法匹配预期场景。** | 字符串数组 | 可缺省，缺省值为空。 |
| `entities` | 能够接收的 Entity 值的集合。**一个 skill 中不建议配置多个 entity。** | 字符串数组 | 可缺省，缺省值为空。 |
| `uris` | 与 Want 中 URI 相匹配的集合。 | 对象数组 | 可缺省，缺省值为空。 |
| `permissions` | 其他应用访问该组件时需申请的权限。 | 字符串数组 | 可缺省，缺省值为空。 |
| `domainVerify` | 是否开启域名校验。 | 布尔值 | 可缺省，缺省值为 `false`。 |

配置规则原文：
> 对于 Entry 类型的 HAP，应用可以配置多个具有入口能力的 skills 标签（即配置了 `ohos.want.action.home` 和 `entity.system.home`）。
> 对于 Feature 类型的 HAP，只有应用可以配置具有入口能力的 skills 标签，服务不允许配置。

`uris` 子标签：`scheme`、`host`、`port`、`path | pathStartWith | pathRegex`（三选一）、`type`、`utd`、`maxFileSupported`、`linkFeature`。
> ⚠️ 文档明确：`scheme`、`host`、`port` 等**字符串类型的标签不支持使用资源索引的方式（$string）配置**。

### 4.6 `extensionAbilities` 标签

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `name` | ExtensionAbility 组件的名称，长度不超过 127 字节。 | 字符串 | **不可缺省**。 |
| `srcEntry` | 代码路径，长度不超过 127 字节。 | 字符串 | **不可缺省**。 |
| `description` | 描述，长度不超过 255 字节，可用资源索引。 | 字符串 | 可缺省，缺省值为空。 |
| `icon` | 图标资源索引。 | 字符串 | 可缺省，缺省值为空。 |
| `label` | 显示名称的资源索引，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `type` | ExtensionAbility 类型。音乐播放器常见：`form`（卡片）、`workScheduler`、`share`、`thumbnail`、`preview`、`print`、`push`、`remoteNotification`、`remoteLocation`、`appService` 等（完整列表见原文档）。 | 字符串 | 可缺省，缺省值为空。 |
| `permissions` | 其他应用访问该 ExtensionAbility 时需申请的权限。 | 字符串数组 | 可缺省，缺省值为空。 |
| `skills` | 能够接收的 Want 特征集。 | 数组 | 可缺省，缺省值为空。 |
| `metadata` | 元信息。**该标签在 type 为 `form` 时不可缺省，且必须存在一个 name 为 `ohos.extension.form` 的对象值，其对应的 resource 值不能缺省。** | 对象数组 | 可缺省，缺省值为空。 |
| `exported` | 是否可以被其他应用调用。 | 布尔值 | 可缺省，缺省值为 `false`。 |
| `extensionProcessMode` | 进程模型：`instance` / `type` / `bundle`（默认 `bundle`）。 | 字符串 | 可缺省，缺省值为 `bundle`。 |
| `dataGroupIds` | dataGroupId 集合。 | 字符串数组 | 可缺省，缺省值为空。 |
| `process` | 组件进程名，**只有 type 为 `embeddedUI` 时可以配置**。**从 API version 14 开始支持**；**仅在 PC/2in1 和 Tablet 设备上生效**。 | 字符串 | 可缺省，缺省值为空。 |
| `uri` | 提供的数据 URI。**type 为 `dataShare` 时不可缺省。** | 字符串 | 可缺省，缺省值为空。 |
| `readPermission` / `writePermission` | 读 / 写该组件数据所需权限。**仅预置系统应用且 type 为 `dataShare` 时生效。** | 字符串 | 可缺省。 |
| `appIdentifierAllowList` | 允许启动此 ExtensionAbility 的应用程序列表。**仅当 type 为 `appService` 支持配置。从 API version 20 开始支持。** | 字符串数组 | 可缺省，缺省值为空。 |

### 4.7 `requestPermissions` 标签

`module.json5` 顶层 `requestPermissions`：

| 属性 | 含义 | 数据类型 | 取值范围 |
| --- | --- | --- | --- |
| `name` | 需要使用的权限名称。 | 字符串 | **必填**，需为系统已定义的权限。 |
| `reason` | 申请权限的原因。**该字段用于应用上架校验，申请 `user_grant`/`manual_settings` 权限时必填并需多语种适配。** 格式为 `$string: ***`；string 资源引用需要在 `string.json` 文件配置标签 `"name": "reason"`。 | 字符串 | **可选填写**（对 user_grant 实为必填）。 |
| `usedScene` | 权限使用的场景，该字段用于应用上架校验。包括 `abilities` 和 `when` 两个子项。 | 对象 | **申请 `user_grant`/`manual_settings` 权限时必填**，其他情况下选填。 |

`usedScene` 子项原文：
> - `abilities`：使用权限的 UIAbility 或者 ExtensionAbility 组件的名称。可以配置为多个 UIAbility 或者 ExtensionAbility 名称的字符串数组。
> - `when`：调用时机。配置此字段，**只能填入固定值 `inuse`（使用时）或 `always`（始终），不能为空。**

> **多 HAP 场景（原文）：** 已在 entry 模块中声明的权限，无需在 feature 模块中重复添加，权限将在整个应用中生效。反之亦然。

**权限声明示例（原文）：**

```json5
{
  "module": {
    "requestPermissions": [
      {
        "name": "ohos.permission.APPROXIMATELY_LOCATION",
        "reason": "$string:approximately_location_permission_reason",
        "usedScene": {
          "abilities": ["FormAbility"],
          "when": "inuse"
        }
      },
      {
        "name": "ohos.permission.USE_BLUETOOTH"
      }
    ]
  }
}
```

**内容规范（原文）：**
> 1. 保持句子简洁，不要加入多余的分割符号。**建议句式**：用于某事。**示例**：用于扫码拍照。
> 2. 用途描述的字串建议小于 72 个字符（即 36 个中文字符，UI 界面显示大约为两行）。不能超过 256 个字符。
> 3. 如果不填写，将展示默认的申请理由。
> 4. 申请「电话、信息、日历、通讯录、通话记录」这五个权限组中的权限时，将展示具体子权限的内容与用途。

### 4.8 完整 `module.json5` 实例（横屏音乐播放器）

```json5
{
  "module": {
    "name": "entry",
    "type": "entry",
    "description": "$string:module_desc",
    "mainElement": "EntryAbility",
    "deviceTypes": [
      "phone",
      "tablet",
      "2in1"
    ],
    "deliveryWithInstall": true,
    "installationFree": false,
    "pages": "$profile:main_pages",
    "metadata": [
      {
        "name": "ohos.ability.window.height",
        "value": "900"
      },
      {
        "name": "ohos.ability.window.width",
        "value": "1600"
      },
      {
        "name": "enable.remove.starting.window",
        "value": "true"
      }
    ],
    "abilities": [
      {
        "name": "EntryAbility",
        "srcEntry": "./ets/entryability/EntryAbility.ets",
        "launchType": "singleton",
        "description": "$string:EntryAbility_desc",
        "icon": "$media:layered_image",
        "label": "$string:EntryAbility_label",
        "startWindowIcon": "$media:startIcon",
        "startWindowBackground": "$color:start_window_background",
        "exported": true,
        "orientation": "landscape",
        "preferMultiWindowOrientation": "landscape",
        "supportWindowMode": [
          "fullscreen",
          "split",
          "floating"
        ],
        "minWindowWidth": 600,
        "maxWindowWidth": 2560,
        "backgroundModes": [
          "audioPlayback"
        ],
        "skills": [
          {
            "entities": [
              "entity.system.home"
            ],
            "actions": [
              "ohos.want.action.home"
            ]
          }
        ],
        "metadata": [
          {
            "name": "ohos.ability.window.isMaximize",
            "value": "true"
          }
        ]
      }
    ],
    "extensionAbilities": [
      {
        "name": "EntryBackupAbility",
        "srcEntry": "./ets/entrybackupability/EntryBackupAbility.ets",
        "type": "backup",
        "exported": false
      }
    ],
    "requestPermissions": [
      {
        "name": "ohos.permission.KEEP_BACKGROUND_RUNNING",
        "reason": "$string:reason_background_running",
        "usedScene": {
          "abilities": [
            "EntryAbility"
          ],
          "when": "always"
        }
      },
      {
        "name": "ohos.permission.INTERNET"
      }
    ]
  }
}
```

> **⚠️ 逐项说明：**
> - `deviceTypes` 里 `"2in1"` 就是鸿蒙电脑 / PC，文档无 `"pc"`。
> - `"orientation": "landscape"` 只保证**启动方向**；运行期必须再调 `setPreferredOrientation(LANDSCAPE)`。
> - `preferMultiWindowOrientation: "landscape"` 让分屏/悬浮窗也能横屏（建议横向游戏类应用配置），对横屏音乐播放器同样合理。
> - `backgroundModes: ["audioPlayback"]` 属于长时任务集合（后台播放），具体类型表以 `task-management/continuous-task.md` 为准。
> - `ohos.permission.KEEP_BACKGROUND_RUNNING` 的具体权限名/申请方式请以 `security/AccessToken/app-permissions.md` 为准；⚠️ 本仓库未下载该页，名字仅供参考，落地前需核对。
> - `installationFree` 文档原文：「该标签在编译构建时自动生成，手动配置不生效。」

---

## 5. app.json5 要点与实例

位置：`工程名称/AppScope/app.json5`。

### 5.1 标签说明（只列相关项）

| 属性名称 | 含义 | 数据类型 | 是否可缺省 |
| --- | --- | --- | --- |
| `bundleName` | 应用的 Bundle 名称。必须为以点号（`.`）分隔的字符串，**至少包含三段**，每段仅允许英文字母、数字、下划线；首段以英文字母开头；不允许多个点号连续出现；**最小长度 7 字节，最大 128 字节**；推荐反域名形式。 | 字符串 | **不可缺省**。 |
| `bundleType` | Bundle 类型。取值：`app`（应用）/ `atomicService`（原子化服务）/ `shared`（共享库应用，**仅系统应用，三方配置后无法安装**）/ `appService`（系统级共享库应用，仅系统应用生效）/ `appPlugin`（应用的插件包，**从 API version 19 开始支持**）。 | 字符串 | 可缺省，**缺省值为 `app`**。 |
| `debug` | 是否可调试。 | 布尔值 | 由 DevEco 编译构建时生成，缺省 `false`。 |
| `icon` | 应用图标资源索引，支持单层 / 分层图标。 | 字符串 | **不可缺省**。 |
| `label` | 应用名称，字符串资源索引，长度不超过 63 字节。 | 字符串 | **不可缺省**。 |
| `description` | 应用描述，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `vendor` | 对应用开发厂商的描述，长度不超过 255 字节。 | 字符串 | 可缺省，缺省值为空。 |
| `versionCode` | 应用版本号，取值范围 0~2147483647。 | 数值 | **不可缺省**。 |
| `versionName` | 向用户展示的版本号，长度不超过 127 字节，推荐 `A.B.C.D` 四段式。 | 字符串 | **不可缺省**。 |
| `minCompatibleVersionCode` | 应用能够兼容的最低历史版本号。**该标签为预留字段，暂未使用。** | 数值 | 可缺省，缺省值等于 `versionCode`。 |
| `minAPIVersion` | 应用运行所需的最小 SDK API 版本，取值范围 0~2147483647。**该标签在应用编译构建时自动生成，手动配置无效**，对应工程级 `build-profile.json5` 中的 `compatibleSdkVersion`。 | 数值 | 构建生成。 |
| `targetAPIVersion` | 应用运行需要的 API 目标版本。**自动生成，手动配置无效**，对应 `targetSdkVersion`（未配置时由 `compileSdkVersion` 生成）。 | 数值 | 构建生成。 |
| `apiReleaseType` | API 目标版本类型：`CanaryN` / `BetaN` / `ReleaseN`。**手动配置无效。** | 字符串 | 构建生成。 |
| `multiProjects` | 是否支持多个工程联合开发。**自动生成，手动配置无效。** | 布尔值 | 构建生成。 |
| `generateBuildHash` | 所有 HAP/HSP 是否由打包工具生成哈希值。**该标签仅对预置应用生效。** | 布尔值 | 可缺省，缺省 `false`。 |
| `assetAccessGroups` | 应用的 Group ID。**仅在应用主模块（entry）下生效。从 API version 18 开始支持。** | 字符串数组 | 可缺省，缺省值为空。 |
| `appEnvironments` | 应用环境变量（`name` / `value`，各不超过 4096 字节）。 | 对象数组 | 可缺省，缺省值为空。 |
| `maxChildProcess` | 自身可创建的子进程最大个数，0 表示不限制。 | 数值 | 可缺省。 |
| `multiAppMode` | 多开模式。`multiAppModeType`：`multiInstance`（**仅支持 2in1 设备**，常驻进程不支持）/ `appClone`；`maxCount`：multiInstance 取值 1~10，appClone 取值 1~5。**仅 bundleType 为 app 的应用的 entry 或 feature 模块配置有效。** | 对象 | 可缺省，缺省值为空。 |
| `hwasanEnabled` | 是否开启 HWAsan 检测。**从 API version 14 开始支持。** | 布尔值 | 可缺省，缺省 `false`。 |
| `ubsanEnabled` | 是否使用 UBSan 检测未定义行为。**从 API version 14 开始支持。** | 布尔值 | 可缺省，缺省 `false`。 |
| `configuration` | 应用字体大小跟随系统配置的能力，profile 文件资源，如 `$profile:configuration`。 | 字符串 | 可缺省。 |
| `startMode` | 启动模式：`mainTask` / `recentTask`。**从 API version 20 开始支持**；**仅支持 phone 和 tablet 设备（不包含自由多窗）**。 | 字符串 | 可缺省，缺省 `mainTask`。 |
| `appPreloadPhase` | 应用预加载阶段。**从 API version 20 开始支持；仅在 PC/2in1 设备上生效。** ⚠️ 不可用于 API 14/15。 | 字符串 | 可缺省。 |
| `cloudStructuredDataSyncEnabled` | 端云结构化数据同步。**从 API version 20 开始支持。** ⚠️ 不可用于 API 14/15。 | 布尔值 | 可缺省，缺省 `false`。 |

### 5.2 ⚠️ 多设备（按设备类型覆盖）键

`app.json5` 支持**按设备类型做特殊配置**，可配置的属性标签为 **`minAPIVersion`**：

| 属性名称 | 含义 |
| --- | --- |
| `tablet` | 对 tablet 设备做的特殊配置。如果使用该属性对 tablet 设备做了特殊配置，则应用在 tablet 设备中会采用此处配置的属性值，并忽略在 app.json5 公共区域的属性值。 |
| `tv` | 对 tv 设备做的特殊配置（同上）。 |
| `wearable` | 对 wearable 设备做的特殊配置（同上）。 |
| `car` | 对 car 设备做的特殊配置（同上）。 |
| `default` | 对 default 设备做的特殊配置（同上）。 |
| `2in1` | **标识对 PC/2in1 设备做的特殊配置，可以配置的属性标签为 `minAPIVersion`。** 如果使用该属性对 PC/2in1 设备做了特殊配置，则应用在 PC/2in1 设备中会采用此处配置的属性值，并忽略在 app.json5 公共区域配置的属性值。 |

> ⚠️ 文档里**没有** `phone` 这个覆盖键（只有 `tablet`/`tv`/`wearable`/`car`/`default`/`2in1`）。公共区域的值即 phone 的值。

### 5.3 完整 `app.json5` 实例

```json5
{
  "app": {
    "bundleName": "com.example.foliamusic",
    "vendor": "example",
    "versionCode": 1000000,
    "versionName": "1.0.0",
    "icon": "$media:layered_image",
    "label": "$string:app_name",
    "description": "$string:description_application",
    "bundleType": "app",
    "debug": false,
    "2in1": {
      "minAPIVersion": 14
    },
    "tablet": {
      "minAPIVersion": 14
    },
    "multiAppMode": {
      "multiAppModeType": "appClone",
      "maxCount": 5
    },
    "appEnvironments": [
      {
        "name": "name1",
        "value": "value1"
      }
    ]
  }
}
```

> **⚠️ `minAPIVersion` / `targetAPIVersion` 在实际工程中由 DevEco Studio 依据工程级 `build-profile.json5` 的 `compatibleSdkVersion` / `targetSdkVersion` / `compileSdkVersion` 自动写入 `app.json5`，手改无效。** API 14/15 目标请在 `build-profile.json5` 里配置，而不是手改 `app.json5`。

---

## 6. ArkUI 自适应布局（手机 / 平板 / PC / 2in1）

### 6.1 `GridRow` / `GridCol` 响应式栅格

`GridRow` 为栅格容器组件，需与栅格子组件 `GridCol` 在栅格布局场景中联合使用。

#### 默认断点（文档原文表）

> 栅格容器以设备的水平宽度（像素单位，单位 **vp**）作为断点依据，定义设备的宽度类型，形成了一套断点规则。
> 栅格容器默认断点将设备宽度分为 xs、sm、md、lg 四类，尺寸范围如下：

| 断点名称 | 取值范围（vp） | 设备描述 |
| --- | --- | --- |
| `xs` | `[0, 320)` | 最小宽度类型设备。 |
| `sm` | `[320, 600)` | 小宽度类型设备。 |
| `md` | `[600, 840)` | 中等宽度类型设备。 |
| `lg` | `[840, +∞)` | 大宽度类型设备。 |

#### 扩展到 6 档（`xs / sm / md / lg / xl / xxl`）

> 允许开发者使用 `BreakPoints` 自定义修改断点的取值范围，**最多支持 6 个断点**，除了默认的 4 个断点外，还可以启用 `xl` 和 `xxl` 断点。

| 断点名称 | 设备描述 |
| --- | --- |
| `xs` | 最小宽度类型设备。 |
| `sm` | 小宽度类型设备。 |
| `md` | 中等宽度类型设备。 |
| `lg` | 大宽度类型设备。 |
| `xl` | 特大宽度类型设备。 |
| `xxl` | 超大宽度类型设备。 |

**单调递增数组规则（原文）：**
> 由于栅格容器默认支持 4 个断点，在不设置断点位置时，**系统为默认断点配置的单调递增数组为 `["320vp", "600vp", "840vp"]`**。开发者使用 `BreakPoints` 最多可支持 6 个断点，因此此单调递增数组**最大长度为 5**。

假设传入的数组是 `[n0, n1, n2, n3, n4]`：

| 断点 | 取值范围 |
| --- | --- |
| `xs` | `[0, n0)` |
| `sm` | `[n0, n1)` |
| `md` | `[n1, n2)` |
| `lg` | `[n2, n3)` |
| `xl` | `[n3, n4)` |
| `xxl` | `[n4, INF)` |

文档给出的示例注释（逐字）：
```ts
breakpoints: {value: ['100vp', '200vp']} // 表示xs、sm、md共3个断点被使用，小于100vp为xs，100vp-200vp为sm，大于200vp为md。
breakpoints: {value: ['320vp', '600vp']} // 表示xs、sm、md共3个断点被使用，小于320vp为xs，320vp-600vp为sm，大于600vp为md。
breakpoints: {value: ['320vp', '600vp', '840vp', '1440vp']} // 表示xs、sm、md、lg、xl共5个断点被使用，…
```

**断点参考物（原文，对 PC 多窗口极关键）：**
> 栅格容器通过监听窗口或容器的尺寸变化进行断点，通过 `reference` 设置断点切换参考物。**考虑到应用可能以非全屏窗口的形式显示，以应用窗口宽度为参照物更为通用。**

```ts
breakpoints: {
  value: ['320vp', '600vp', '840vp', '1440vp', '1600vp'],
  reference: BreakpointsReference.WindowSize
}
```

**`onBreakpointChange`（原文示例）：**
```ts
.onBreakpointChange((breakPoint) => {
  this.currentBp = breakPoint
})
```

#### `columns` 默认值（⚠️ API 20 前后不同，API 14/15 用前者）

> - **API version 20 之前，`columns` 默认值为 12**，即在未设置 columns 时，任何断点下，栅格布局均被分成 12 列。
> - API version 20 及以后，`columns` 默认值为 `{ xs: 2, sm: 4, md: 8, lg: 12, xl: 12, xxl: 12 }`。

`columns` 支持 `number` 和 `GridRowColumnOption`：

```ts
GridRow({
  columns: {
    xs: 2,   // 窗口宽度落入xs断点上，栅格容器分为2列。
    sm: 4,   // 窗口宽度落入sm断点上，栅格容器分为4列。
    md: 8,
    lg: 12,
    xl: 12,
    xxl: 12
  },
  breakpoints: {
    value: ['320vp', '600vp', '840vp', '1440vp', '1600vp'],
    reference: BreakpointsReference.WindowSize
  }
}) {
  GridCol({ span: 1 }) { /* ... */ }
}
```

`GridCol` 的 `span` / `offset` / `order` 均支持 `number` 和 6 档对象：
```ts
GridCol({ span: { xs: 1, sm: 2, md: 3, lg: 4 } }){ }
GridCol({ offset: { xs: 2, sm: 2, md: 2, lg: 2 }, span: 1 }){ }
GridCol({ order: { xs: 1, sm: 2, md: 3, lg: 4 }, span: 1 }){ }
```
> 仅部分设置 sm、md 的栅格列数时，未配置的 xs、lg、xl、xxl 设备根据「列数补全」取默认值。

**文档结论原文（可作为「用 GridRow 一次开发多端」的依据）：**
> 栅格组件提供了丰富的自定义能力，功能非常灵活和强大。只需要明确栅格在不同断点下的 `columns`、`margin`、`gutter` 及 `span` 等参数，即可确定最终布局，**无需关心具体的设备类型及设备状态（如横竖屏）等**。

### 6.2 `Navigation` 的 `mode` 与 `NavDestination`（宽屏双栏）

`Navigation` 提供了两种布局样式：**单栏布局、分栏布局**。分栏布局一般适用于宽屏设备。

**`mode(value: NavigationMode)`** —— 默认值 `NavigationMode.Auto`，「自适应：基于组件宽度自适应单栏和双栏」。

`NavigationMode` 枚举说明（原文）：

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `Stack` | 0 | 导航页与内容区独立显示，相当于两个页面。 |
| `Split` | 1 | 导航页与内容区分两栏显示。**1.** navBarWidth 最终取值与开发者设置值的关系参见表 1。**2.** 缩小组件尺寸时，先缩小内容区的尺寸至 minContentWidth，然后再缩小导航页的尺寸至 minNavBarWidth。若继续缩小，先缩小内容区，内容区消失后再缩小导航页。**3.** 设置导航页为固定尺寸时，若持续缩小组件尺寸，导航页最后压缩显示。**4.** 若只设置了 navBarWidth 属性，则导航页宽度为 navBarWidth，且分割线不可拖动。**5.** 分割线的热区左右各 2vp，建议避让 4vp 以上。**6.** Split 模式下，内容区若只存在一个页面，则页面左上角不会显示返回按钮。 |
| `Auto` | 2 | **API version 9 及之前**版本，Navigation 宽度 >=520vp 时采用 Split 模式显示；< 520vp 时采用 Stack 模式显示。**从 API version 10 开始**：Navigation 宽度 >=**600vp** 时采用 Split 模式显示；< 600vp 时采用 Stack 模式显示，**600vp 等于 minNavBarWidth(240vp) + minContentWidth(360vp)**。 |
| `AUTO_WITH_ASPECT_RATIO` | 3 | Navigation 宽度 >=600vp 且高宽比 <=1.2 时采用 Split；否则 Stack。⚠️ **API 24+，不可用于 API 14/15。** |

**分栏相关接口（`arkts-navigation-split-mode.md`）：**

| 接口 | 说明 |
| --- | --- |
| `navBarPosition` | 控制导航栏显示位置（`NavBarPosition.Start` / `.End`），**会被系统语言影响**：LTR 语言体系下 `Start` 是左侧，RTL（阿拉伯语）下 `Start` 是右侧。 |
| `enableDragBar`（**API 14+**） | 控制是否显示分栏的拖动按钮。API 14/15 可用。 |
| `navBarWidth` | 控制导航栏的宽度。仅在 `mode` 为 `NavigationMode.Auto` 或 `NavigationMode.Split` 时生效。 |
| `navBarWidthRange`（API 10+） | 设置导航栏宽度可调整的范围。 |
| `minContentWidth`（API 10+） | 控制分栏子页的最小宽度。 |
| `hideNavBar` | 控制导航栏显示状态，默认 `false`。**如果同时将 `mode` 配置为 `NavigationMode.Split` 且 `hideNavBar` 设置为 `true`，则实际效果会显示为单栏。** |
| `enableModeChangeAnimation`（**API 15+**） | 控制是否开启单双栏切换的动画，默认开启。API 15 可用，API 14 不可用。 |
| `splitPlaceholder` | ⚠️ **API 20+，不可用于 API 14/15。** 设置分栏模式下内容区的默认占位页。占位页仅作为 UI 展示页，仅分栏模式空栈的情况下才展示，不受路由栈管理也不可获焦和响应事件。 |
| `onNavigationModeChange(callback: (mode: NavigationMode) => void)`（API 11+） | 单双栏显示状态发生变更时触发。回调参数 `mode`：`NavigationMode.Split`（当前 Navigation 显示为双栏）/ `NavigationMode.Stack`（显示为单栏）。 |

**分栏最小可用示例（原文示例精简）：**

```ts
@Entry
@Component
struct Index {
  private stack: NavPathStack = new NavPathStack();

  build() {
    Navigation(this.stack) {
      NewsHome().width('100%').height('100%')   // 左侧导航栏内容
    }
    .mode(NavigationMode.Split)      // 或 NavigationMode.Auto 让系统按 600vp 阈值切换
    .enableDragBar(true)             // API 14+
    .hideNavBar(false)
    .navBarWidthRange([100, 700])    // NavBar 区域宽度范围
    .minContentWidth(100)            // 子页区域最小宽度
    .hideTitleBar(true)
    .hideToolBar(true)
    .onNavigationModeChange((mode: NavigationMode) => {
      // NavigationMode.Split / NavigationMode.Stack
    })
  }
}
```

**`NavDestination`（右侧内容区页面）：** 通过 `NavPathStack.pushPath({ name, param })` 路由到 `NavDestination` 子页；在 `onReady((ctx: NavDestinationContext) => { let param = ctx.pathInfo.param; })` 里取参数。路由表在 `resources/base/profile/router_map.json`（由 `module.json5` 的 `routerMap` 指向）：

```json
{
  "routerMap": [
    {
      "name": "NewsDetail",
      "pageSourceFile": "src/main/ets/pages/navigation/splitmode/NewsDetail.ets",
      "buildFunction": "NewsDetailPageBuilder",
      "data": { "description": "this is DetailPageA" }
    }
  ]
}
```

> **⚠️ 页面级旋转锁定：** `window-faqs.md` 提到可通过组件的 `preferredOrientation` 属性实现「单一页面（Navigation）的禁用旋转」。**该属性标注为 API 19+，API 14/15 不可用。**

### 6.3 运行期监听尺寸变化

#### 方案 A：`window.on('windowSizeChange')`（API 7+）

```ts
on(type: 'windowSizeChange', callback: Callback<Size>): void
off(type: 'windowSizeChange', callback?: Callback<Size>): void
```
> 开启 / 关闭窗口尺寸变化的监听。**仅在主线程调用。**
> 回调参数 `Size`：**窗口大小，单位为 px**（`width` / `height`，均为整数）。

```ts
try {
  windowClass.on('windowSizeChange', (data) => {
    console.info('Succeeded in enabling the listener for window size changes. Data: ' + JSON.stringify(data));
  });
} catch (exception) { /* ... */ }
```

> ⚠️ **单位是 px**：要换算成 vp 需除以 `display.Display.densityPixels`。
> ⚠️ 文档另有 `SizeInVP`（**API 23+**，单位 vp）——API 14/15 不可用。

#### 方案 B：媒体查询 `@ohos.mediaquery`

```ts
// ⚠️ 全局 matchMediaSync 从 API 7 开始支持，从 API version 18 开始废弃
mediaquery.matchMediaSync(condition: string): MediaQueryListener
```

> ⚠️ **推荐（API 18+）写法：** 先通过 `UIContext.getMediaQuery()` 获取 `MediaQuery` 对象再调用：
> ```ts
> listener: mediaquery.MediaQueryListener = this.getUIContext().getMediaQuery().matchMediaSync('(orientation: landscape)');
> ```
> **对 API 14/15 而言，两种写法都可用**（全局写法只是「废弃」，未移除）。

也可以直接注册为组件成员（文档示例）：
```ts
listener: mediaquery.MediaQueryListener = mediaquery.matchMediaSync('(orientation: landscape)');

aboutToAppear() {
  this.listener.on('change', (mediaQueryResult: mediaquery.MediaQueryResult) => { /* ... */ });
}
aboutToDisappear() {
  this.listener.off('change');
}
```

**媒体特征表（原文，节选）：**

| 类型 | 说明 |
| --- | --- |
| `height` / `min-height` / `max-height` | 应用页面可绘制区域的高度。 |
| `width` / `min-width` / `max-width` | 应用页面可绘制区域的宽度。 |
| `resolution` / `min-resolution` / `max-resolution` | 设备的分辨率，支持 dpi、dppx、dpcm。 |
| `orientation` | 屏幕的方向。可选值：`orientation: portrait`（设备竖屏）；`orientation: landscape`（设备横屏）。 |
| `device-height` / `min-device-height` / `max-device-height` | 设备的高度。 |
| `device-width` / `min-device-width` / `max-device-width` | 设备的宽度。**`device-width` 当前仅在应用初始化时保存一次，不会随设备宽度变化实时更新，例如折叠屏的折叠展开场景。** |
| `device-type` | 设备的类型。可选值：**default、phone、tablet、tv、car、wearable、2in1**。 |
| `round-screen` | 屏幕类型，圆形屏幕为 true，非圆形屏幕为 false。 |
| `dark-mode` | 系统当前的深浅模式。可选值：true、false。 |

> **单位（原文）：** 比较 height、width 等宽高尺寸时，**支持 vp 和 px 单位，无单位时默认为 px**。
> 所以写 `matchMediaSync('(width>=600vp)')` 是合法的（显式 vp）。
> **⚠️ 注意：** 本仓库下载的 `arkts-layout-development-media-query.md` 是唯一给出媒体特征全表的页面，文中没有 `(width>=600vp)` 这一字面示例；该写法是依据「支持 vp 单位」与「媒体逻辑范围操作符 `>=`」两段原文推导的，**标记为 ⚠️ 推导用法**。

**媒体逻辑操作符：** `and` / `or` / `not`（必须搭配 screen）/ `only`（必须搭配 screen）/ `,`（等价 or）；范围操作符：`<=`、`>=`、`<`、`>`。
> **⚠️ 卡片中使用媒体查询，只支持 `height`、`width`。**

#### 方案 C（推荐）：`GridRow` 的 `onBreakpointChange`

> **⚠️ 下面是本文的推荐结论（综合文档，非文档原句）：**
> 1. **页面布局切换** → 优先用 `GridRow` + `breakpoints.reference = BreakpointsReference.WindowSize` + `onBreakpointChange`。理由来自文档：栅格「以应用窗口宽度为参照物更为通用」，且「无需关心具体的设备类型及设备状态（如横竖屏）」。PC/2in1 的自由缩放窗口下，组件宽度断点比设备类型判断正确得多。
> 2. **窄/宽两套页面形态** → 优先用 `Navigation` 的 `NavigationMode.Auto`（阈值 600vp）+ `onNavigationModeChange`，它是官方为「宽屏双栏」设计的现成开关。
> 3. `mediaquery` 适合「本身与宽度无关、只关心方向/深浅色/设备类型」的场景（如 `(orientation: landscape)`、`(dark-mode: true)`、`(device-type: 2in1)`）。
> 4. `window.on('windowSizeChange')` 适合需要**真实窗口像素尺寸**（例如做自绘频谱、计算精确布局比例）的场景；注意单位是 px。

### 6.4 `display` API（屏幕尺寸与密度）

导入：
```ts
import { display } from '@kit.ArkUI';
```

取默认屏幕（API 9+）：
```ts
getDefaultDisplaySync(): Display
```
```ts
let displayClass: display.Display | null = null;
try {
  displayClass = display.getDefaultDisplaySync();
  let orientation = displayClass.Orientation;
} catch (exception) {
  console.error(`Failed to get default display. Code: ${exception.code}, message: ${exception.message}`);
}
```

`Display` 关键属性（原文）：

| 属性 | 类型 | 说明 |
| --- | --- | --- |
| `id` | number | 显示设备的屏幕 ID，大于等于 0 的整数。 |
| `name` | string | 显示设备的名称。 |
| `alive` | boolean | 显示设备的启用状态。 |
| `state` | `DisplayState` | 显示设备的状态。 |
| `refreshRate` | number | 显示设备当前采用的刷新率，单位为 Hz。 |
| `rotation` | number | 显示设备的屏幕顺时针旋转角度。0 = 0°（标准显示方向）、1 = 90°、2 = 180°、3 = 270°。 |
| `width` | number | 显示设备的屏幕宽度，**单位为 px**，整数。 |
| `height` | number | 显示设备的屏幕高度，**单位为 px**，整数。 |
| `densityDPI` | number | 显示设备的物理像素密度，每英寸上的像素点数，浮点数，单位为 px。一般取值 160.0、480.0 等。 |
| `orientation`（API 10+） | `display.Orientation` | 表示显示设备当前显示的方向。 |
| `densityPixels` | number | 显示设备逻辑像素的密度，代表物理像素与逻辑像素的缩放系数。**取值范围在 [0.5, 4.0]。** 一般取值 1.0、3.0 等。 |
| `scaledDensity` | number | 显示设备上的字体的缩放因子，通常与 `densityPixels` 相同。 |
| `xDPI` / `yDPI` | number | x / y 轴方向中每英寸屏幕的确切物理像素值。 |

`display.DisplayState` 枚举：`STATE_UNKNOWN`=0、`STATE_OFF`=1、`STATE_ON`=2、`STATE_DOZE`=3、`STATE_DOZE_SUSPEND`=4、`STATE_VR`=5、`STATE_ON_SUSPEND`=6。

#### ⚠️⚠️ `display.Orientation` ≠ `window.Orientation`（极易踩坑）

`display.Orientation`（屏幕方向，API 10+）：

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `PORTRAIT` | 0 | 表示设备当前以竖屏方式显示。 |
| `LANDSCAPE` | 1 | 表示设备当前以横屏方式显示。 |
| `PORTRAIT_INVERTED` | 2 | 表示设备当前以反向竖屏方式显示。 |
| `LANDSCAPE_INVERTED` | 3 | 表示设备当前以反向横屏方式显示。 |

**文档原文（`window-faqs.md`）：**
> 通过 `setPreferredOrientation` 接口设置旋转策略为 `LANDSCAPE`，此时通过以上步骤获取到的 `Orientation` 属性为**反向横屏（即 `LANDSCAPE_INVERTED`）**，这是因为**窗口的方向与屏幕的方向定义不一致**。开发者也可以通过 `convertOrientationAndRotation()` 来获取转换结果。

> ⚠️ `convertOrientationAndRotation` 标注为 **API 23+**，**API 14/15 不可用**。因此在 API 14/15 上判断「当前是否横屏」请用 **`mediaquery` 的 `(orientation: landscape)`**，而不要用 `display.Orientation`。文档另明确：
> **「应用窗口的宽高比与屏幕属性的 Orientation 没有直接关系，不建议根据屏幕属性的 Orientation 来做窗口布局适配。屏幕属性的 Orientation 仅用于辅助 sensor 和相机的方向修正。」**

#### 附加：密度设置（API 15 相关）

| 接口 | 起始版本 | 说明 |
| --- | --- | --- |
| `windowStage.setDefaultDensityEnabled(enabled: boolean)` | API 12+ | 设置是否使用系统默认密度。 |
| `windowStage.setCustomDensity(density: number)` | **API 15+** | 设置自定义密度。API 15 可用，API 14 不可用（同页另有 API 20+ 的重载）。 |

---

## 7. 安全区、刘海 / 挖孔、避免拉伸

### 7.1 `expandSafeArea`（组件级扩展安全区）

```ts
expandSafeArea(types?: Array<SafeAreaType>, edges?: Array<SafeAreaEdge>): T
```
> 控制组件扩展其安全区域。

**参数（原文）：**

| 参数名 | 类型 | 必填 | 说明 |
| --- | --- | --- | --- |
| `types` | `Array<SafeAreaType>` | 否 | 配置扩展安全区域的类型。**未添加 Metadata 配置项时，页面不避让挖孔，`CUTOUT` 类型不生效。** 默认值：`[SafeAreaType.SYSTEM, SafeAreaType.CUTOUT, SafeAreaType.KEYBOARD]`。非法值：按默认值处理。 |
| `edges` | `Array<SafeAreaEdge>` | 否 | 配置扩展安全区域的边缘。默认值：`[SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM, SafeAreaEdge.START, SafeAreaEdge.END]`。非法值：按默认值处理。扩展至所有避让区域。 |

**`SafeAreaType`：** `SYSTEM`=0（系统默认非安全区域，包括状态栏、导航栏）、`CUTOUT`=1（设备的非安全区域，例如刘海屏或挖孔屏区域）、`KEYBOARD`=2（软键盘区域）。

**`SafeAreaEdge`：** `TOP`=0、`BOTTOM`=1、`START`=2（前部区域）、`END`=3（尾部区域）。

**官方注意事项（逐条，对横屏沉浸式布局非常关键）：**
> - 设置 `expandSafeArea` 属性进行组件绘制扩展时，**建议组件尺寸不要设置固定宽高（百分比除外）**，当设置固定宽高（包括设置 `'auto'`）时，**扩展安全区域的方向只支持 `[SafeAreaEdge.TOP, SafeAreaEdge.START]`，扩展后的组件尺寸保持不变。**
> - **安全区域不会限制内部组件的布局和大小，不会裁剪内部组件。**
> - 当父容器为滚动容器时，组件设置 `expandSafeArea` 属性后，自身不会延伸，但仍可触发其子节点中设置了 `expandSafeArea` 的延伸范围更新。
> - 设置 `expandSafeArea()` 时，不传参，走默认值处理；**设置 `expandSafeArea([],[])` 时，相当于入参是空数组，此时 `expandSafeArea` 属性设置无效。**
> - 组件设置 `expandSafeArea` 生效的条件为：1. type 为 `SafeAreaType.KEYBOARD` 时默认生效，表现为组件不避让键盘。2. 设置其他 type，**组件的边界与安全区域重合时组件能够延伸到安全区域下**。例如：设备顶部状态栏高度 100，那么组件在屏幕中的绝对位置需要为 `0 <= y <= 100`。
> - 组件延伸到避让区时，**在避让区的事件如点击事件等可能会被系统拦截，优先给状态栏等系统组件响应。**
> - **滚动类容器内的组件不建议设置 `expandSafeArea` 属性**，如果设置，需要按照组件嵌套关系，将当前节点到滚动类祖先容器间所有直接节点设置 `expandSafeArea` 属性，否则 `expandSafeArea` 属性在滚动后可能会失效。
> - `expandSafeArea` 属性**仅作用于当前组件，不会向父组件或子组件传递**，因此使用过程中，所有相关组件均需配置。
> - 同时设置 `expandSafeArea` 和 `position` 属性时，**`position` 属性会优先生效**，`expandSafeArea` 属性会后生效。对于未设置 `position`、`offset` 等绘制属性的组件，如果其边界未与避让区重叠，设置 `expandSafeArea` 属性将不生效。
> - 对于 `expandSafeArea` 属性无法生效的场景，若要将组件部署在避让区，需要手动调整组件的坐标。

**`ignoreLayoutSafeArea`（API 20+，⚠️ 不可用于 API 14/15）** 及 `LayoutSafeAreaType` / `LayoutSafeAreaEdge` 同为后期能力。

### 7.2 窗口级避让区 `getWindowAvoidArea`（API 9+）

```ts
getWindowAvoidArea(type: AvoidAreaType): AvoidArea
```
> 获取当前窗口避让区域。

**文档对主窗口的约束（原文，PC/2in1 上极其关键）：**
> - 自由窗口状态的自由悬浮窗口模式（即窗口模式为 `window.WindowStatusType.FLOATING`）下，仅存在固定态软键盘（`AvoidAreaType` 为 `TYPE_KEYBOARD`）类型的避让区域。
> - 主窗口在非自由窗口状态的自由悬浮窗口模式下，仅存在系统栏（`AvoidAreaType` 为 `TYPE_SYSTEM`）类型的避让区域。
> - **主窗口在其余场景下，仅当在非自由悬浮窗口模式下或设备类型为 Phone 和 Tablet，才能通过此接口获取计算后的避让区域，否则获取的避让区域为空。**
> - 子窗口在非自由窗口状态或非自由悬浮窗口模式下，仅当窗口的位置和大小与主窗口一致时，才能通过此接口获取计算后的避让区域，否则获取的避让区域为空。

> **⚠️ 即：在 PC/2in1（自由窗口）上，`getWindowAvoidArea` 常常返回空避让区。** 横屏安全区逻辑必须以「避让区可能为空」为前提写。

**`AvoidAreaType` 枚举（原文）：**

| 名称 | 值 | 说明 |
| --- | --- | --- |
| `TYPE_SYSTEM` | 0 | 系统默认区域。包含状态栏和三键导航栏区域。 |
| `TYPE_CUTOUT` | 1 | 挖孔区域。 |
| `TYPE_SYSTEM_GESTURE` | 2 | 侧边返回手势区域。**当前所有设备均无此类型避让区域。** |
| `TYPE_KEYBOARD` | 3 | 固定态软键盘区域。 |
| `TYPE_NAVIGATION_INDICATOR` | 4 | 底部导航区域。当三键导航显示时，底部导航避让区域始终存在。 |
| `TYPE_FLOAT_NAVIGATION` | 5 | ⚠️ **API 26.0.0**，不可用于 API 14/15。 |

用法（官方示例）：
```ts
let type = window.AvoidAreaType.TYPE_SYSTEM;
try {
  let avoidArea = windowClass.getWindowAvoidArea(type);
} catch (exception) { /* ... */ }
```
**适用场景（原文）：**
> - 在 `onWindowStageCreate()` 方法中，获取应用启动时的初始布局避让区域时可调用该接口。
> - 当应用内子窗需要临时显示，对显示内容做布局避让时可调用该接口。

**`on('avoidAreaChange')`（API 9+）** 可监听避让区变化，文档列出的典型触发场景原文：
> 应用窗口在全屏模式、悬浮模式、分屏模式之间的切换；**应用窗口旋转**；可折叠设备在屏幕折叠状态发生变化；应用窗口在多设备之间的流转。

> ⚠️ 另有 `getWindowAvoidAreaIgnoringVisibility`（**API 22+**），不可用于 API 14/15。

### 7.3 避免「拉伸变形」

文档未提供「禁止拉伸」的专用开关，但有明确推荐的手段（`arkts-layout-development-overview.md` 原文）：

> - **拉伸**：容器组件尺寸发生变化时，增加或减小的空间全部分配给容器组件内指定区域。
>   `flexGrow` 和 `flexShrink` 属性：1. `flexGrow` 基于父容器的剩余空间分配来控制组件拉伸。2. `flexShrink` 设置父容器的压缩尺寸来控制组件压缩。
> - **缩放**：子组件的宽高按照预设的比例，随容器组件发生变化，且变化过程中**子组件的宽高比不变**。
>   `aspectRatio` 属性指定当前组件的宽高比来控制缩放，公式为：`aspectRatio = width / height`。
> - **占比**：`layoutWeight` 属性，使得子元素自适应占满剩余空间；子组件的宽高设置为百分比。
> - **隐藏**：通过 `displayPriority` 属性来控制组件的显示和隐藏。

> **⚠️ 结论（推导）：** 横屏音乐播放器的封面/频谱等**有固有宽高比的元素**应使用 `aspectRatio`（保持宽高比不变），而**需要填满/让位的容器**使用 `layoutWeight` / `flexGrow` / 百分比宽度。绝对定位（`position`）文档明确警告「对于不同尺寸的设备，使用绝对定位的适应性会比较差，在屏幕的适配上有缺陷」。

**窗口宽高比约束（配置侧，可用于阻止用户把窗口拉成不合理的比例）：**
- `abilities[].maxWindowRatio` / `minWindowRatio` / `maxWindowWidth` / `minWindowWidth` / `maxWindowHeight` / `minWindowHeight`（单位 vp）。
- 运行时：`setAspectRatio`（API 10+）/ `setContentAspectRatio`（API 21+，⚠️ 不可用于 API 14/15）。FAQ 原文：
  > 应用开发中，推荐使用 `setContentAspectRatio()` 设置窗口内容布局的比例。……仅主窗可设置，且仅在自由悬浮窗口模式（即窗口模式为 `window.WindowStatusType.FLOATING`）下生效。API version 21 以前的版本，请使用 `setAspectRatio()` 设置窗口内容布局。

### 7.4 沉浸式与安全区的关系

`window-terminology.md` 原文：
> 应用窗口进入沉浸式布局之后，**页面的所有组件布局范围从安全区域扩展为整个窗口**。可以通过 `isImmersiveLayout` 判断当前窗口是否处于沉浸式布局。

> ⚠️ `isImmersiveLayout` 标注为 **API 20+**，**API 14/15 不可用**。

---

## 8. 推荐的整体策略

> **⚠️ 本章是综合前文文档事实给出的工程建议，不是文档原句。** 每条结论后面标注了它所依赖的文档事实。

**核心矛盾：** 手机/平板上 `setPreferredOrientation(LANDSCAPE)` 能真正锁死横屏；**PC/2in1 上应用默认处于自由窗口，文档明确「系统忽略此旋转策略，接口可正常调用，但应用显示方向并不会改变」**（§1.4）。因此**不能**把「窗口是否横屏」当作布局前提。

**推荐做法（分层设计）：**

1. **配置侧**：`app.json5` 的 `bundleType: "app"`；`module.json5` 的 `deviceTypes: ["phone","tablet","2in1"]`、`abilities[].orientation: "landscape"`（启动即横屏）、`abilities[].preferMultiWindowOrientation: "landscape"`（悬浮窗/上下分屏也横屏）。
   *依据：§3 表格的 `2in1` 定义；§4.4 `orientation` 与 `preferMultiWindowOrientation` 取值表。*

2. **外壳侧（`EntryAbility.onWindowStageCreate`）**：取主窗口 → `setPreferredOrientation(window.Orientation.LANDSCAPE)` → `setWindowLayoutFullScreen(true)` → `setWindowSystemBarEnable([])` → 只在**播放页可见期间** `setWindowKeepScreenOn(true)`，离开即设回 `false`。
   *依据：§1.1/§1.3 官方示例、§2.2 方式一/方式二、§2.3 文档对「音频播放不使用常亮接口」的警告。*

3. **不要以「横屏成功」为分支**：用 `aspectRatio` 描述封面等固有比例元素，用 `GridRow` + `breakpoints.reference = BreakpointsReference.WindowSize` + `onBreakpointChange`（断点 `320/600/840vp`，PC 宽窗再加 `1440/1600vp`）驱动版式；用 `Navigation(mode: NavigationMode.Auto)` 的 600vp 阈值在手机横屏（Stack）与平板/PC 宽窗（Split 双栏）之间自动切换。
   *依据：§6.1「以应用窗口宽度为参照物更为通用」「无需关心具体的设备类型及设备状态（如横竖屏）」；§6.2 `Auto` 阈值 600vp = 240 + 360。*

4. **PC/2in1 上「优雅降级」**：把「横屏」理解为**内容设计上的横向优先**，而非窗口强制。PC 用户可以把窗口拉成任意比例，所以：
   - 用 `GridRow` 断点让双栏/三栏布局随窗口宽度自适应，缩到窄宽度时自动退回单栏（`Navigation` 的 `Auto` 已内置这一行为）；
   - 用 `aspectRatio` 保护封面、歌词等元素不变形；
   - 用 `abilities[].minWindowWidth/minWindowHeight`（vp）给出合理的最小窗口尺寸，避免布局被压垮；
   - 安全区按「`getWindowAvoidArea` 在 PC 自由窗口下**可能返回空**」来写容错分支；需要延伸到状态栏/挖孔时用 `expandSafeArea`，并注意「不设固定宽高时扩展方向才完整」。
   *依据：§7.2 主窗口避让区约束原文；§7.1 `expandSafeArea` 注意事项；§4.4 窗口尺寸字段；§7.3 `aspectRatio`。*

5. **2in1 上的窗口体验加成（可选，均为 PC 专属）**：`metadata` 里配 `ohos.ability.window.isMaximize = "true"` 让主窗最大化启动、`ohos.ability.window.supportWindowModeInFreeMultiWindow = "fullscreen,split,floating"`；也可用 `windowStage.setWindowRectAutoSave()`（API 14+）记忆窗口尺寸。
   *依据：§4.3 窗口元数据表与优先级原文。*

6. **避免的写法**：不要用 `display.Orientation` 判断横竖屏（文档明确「不建议根据屏幕属性的 Orientation 来做窗口布局适配」，且 `display.getDefaultDisplaySync().Orientation` 在 `LANDSCAPE` 策略下会返回 `LANDSCAPE_INVERTED`）；不要用 `window.Orientation.LOCKED`（FAQ 点名不建议）；不要依赖 `setPreferredOrientation` 在 PC 上生效。
   *依据：§6.4 与 §1.2 相关原文。*

---

## 附：本文引用到的本地文档清单

| 文档 | 用途 |
| --- | --- |
| `_docs\zh-cn__application-dev__windowmanager__window-rotation.md` | 旋转策略分类、固定/自动/临时/其他方向类型表、自由窗口与无 sensor 设备的行为限制 |
| `_docs\zh-cn__application-dev__windowmanager__application-window-stage.md` | 主窗口获取、loadContent、沉浸式两种做法 |
| `_docs\zh-cn__application-dev__windowmanager__window-terminology.md` | 自由窗口定义、2in1/Tablet/Phone 支持情况、沉浸式布局定义 |
| `_docs\zh-cn__application-dev__windowmanager__window-faqs.md` | 横竖屏切换 FAQ、保持横屏 FAQ、获取设备横竖屏状态、`LOCKED` 不建议的原文 |
| `_docs\zh-cn__application-dev__windowmanager__window-overview.md` | phone 设备用作 deviceTypes 的旁证 |
| `_docs\zh-cn__application-dev__windowmanager__window-config-m.md` | 窗口 metadata 名（`ohos.ability.window.*`）与优先级 |
| `_docs\zh-cn__application-dev__quick-start__module-configuration-file.md` | deviceTypes 表、abilities（含 orientation）、skills、extensionAbilities、requestPermissions、distributionFilter |
| `_docs\zh-cn__application-dev__quick-start__app-configuration-file.md` | app.json5 全表、2in1/tablet/tv/wearable/car/default 覆盖键 |
| `_docs\zh-cn__application-dev__quick-start__module-structure.md` | FA 模型 deviceType（含 liteWearable）辨析 |
| `_docs\zh-cn__application-dev__security__AccessToken__declare-permissions.md` | requestPermissions 的 name/reason/usedScene 规则与文案规范 |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkts-apis-window-Window.md` | setPreferredOrientation / getPreferredOrientation / setWindowLayoutFullScreen / setWindowSystemBarEnable / setWindowSystemBarProperties / setWindowKeepScreenOn / on('windowSizeChange') / getWindowAvoidArea / on('rotationChange') |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkts-apis-window-WindowStage.md` | getMainWindowSync / getMainWindow / loadContent 三个重载 / setDefaultDensityEnabled / setCustomDensity |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkts-apis-window-e.md` | Orientation 枚举、AvoidAreaType 枚举（带 API 版本上标） |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkts-apis-window-i.md` | Size（px）/ SizeInVP（vp, API 23+） |
| `_docs\zh-cn__application-dev__reference__apis-arkui__js-apis-display.md` | Display 属性表与 display.Orientation |
| `_docs\zh-cn__application-dev__reference__apis-arkui__js-apis-mediaquery.md` | matchMediaSync 签名与废弃说明 |
| `_docs\zh-cn__application-dev__ui__arkts-layout-development-grid-layout.md` | 断点表、BreakPoints、columns、onBreakpointChange |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkui-ts__ts-container-gridrow.md` | GridRow/BreakPoints 参考 |
| `_docs\zh-cn__application-dev__ui__arkts-navigation-split-mode.md` | 分栏接口、mode/navBarPosition/minContentWidth |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkui-ts__ts-basic-components-navigation.md` | NavigationMode 枚举与 Auto 阈值 |
| `_docs\zh-cn__application-dev__ui__arkts-layout-development-media-query.md` | 媒体特征全表（含 device-type = phone/tablet/2in1…） |
| `_docs\zh-cn__application-dev__ui__arkts-layout-development-overview.md` | 拉伸/缩放/占比/隐藏、`aspectRatio`、绝对定位警告 |
| `_docs\zh-cn__application-dev__reference__apis-arkui__arkui-ts__ts-universal-attributes-expand-safe-area.md` | expandSafeArea / SafeAreaType / SafeAreaEdge |
