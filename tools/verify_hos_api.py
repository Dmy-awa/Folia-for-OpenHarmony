"""Cross-check every HarmonyOS API symbol used by the project against the SDK
`.d.ts` declarations.

Point this at your HarmonyOS SDK's `ets/api` directory via the HOS_API_DIR
environment variable, e.g.

    $env:HOS_API_DIR = "C:\\Program Files\\Huawei\\DevEco Studio\\sdk\\HarmonyOS-NEXT-DB1\\openharmony\\ets\\api"
    python tools/verify_hos_api.py

There is no DevEco toolchain / ArkTS compiler in the authoring environment, so
this is the strongest available correctness signal for API names, enum members
and interface fields.

Each check is a (declaration file, symbol) pair. A symbol passes if it appears as
a whole word in that file. For interface members the check is deliberately loose
(word presence) because interface bodies are large; the goal is to catch
misspelled or non-existent API names, which is the failure mode that actually
costs a build round-trip.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# Windows 控制台默认是 GBK，中文与符号会直接抛 UnicodeEncodeError
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

# Default points at the declaration set this project was verified against.
API_DIR = Path(os.environ.get("HOS_API_DIR", r"D:\HarmonyOS_Development_API\23\ets\api"))

# (declaration file, [symbols that must appear as whole words])
CHECKS: list[tuple[str, list[str]]] = [
    ("@ohos.multimedia.avsession.d.ts", [
        "createAVSession", "AVSessionType", "AVMetadata", "AVPlaybackState",
        "PlaybackPosition", "PlaybackState", "LoopMode", "AVQueueItem",
        "AVMediaDescription", "AVControlCommandType", "AVSession",
        # playback state enum members
        "PLAYBACK_STATE_PREPARE", "PLAYBACK_STATE_PLAY", "PLAYBACK_STATE_PAUSE",
        "PLAYBACK_STATE_STOP", "PLAYBACK_STATE_COMPLETED", "PLAYBACK_STATE_ERROR",
        "PLAYBACK_STATE_IDLE",
        # loop mode members used
        "LOOP_MODE_SEQUENCE", "LOOP_MODE_SINGLE", "LOOP_MODE_LIST", "LOOP_MODE_SHUFFLE",
        # metadata fields we set
        "assetId", "previousAssetId", "nextAssetId", "mediaImage", "lyric", "subtitle",
        # session methods
        "setAVMetadata", "setAVPlaybackState", "setAVQueueItems", "setAVQueueTitle",
        "activate", "deactivate", "destroy", "getValidCommands",
    ]),

    ("@ohos.multimedia.media.d.ts", [
        "createAVPlayer", "AVPlayer", "AVPlayerState", "AVFileDescriptor",
        "StateChangeReason", "BufferingInfoType", "MediaType", "PlaybackStrategy",
        "fdSrc", "audioRendererInfo", "audioInterruptMode", "setPlaybackStrategy",
        "prepare", "play", "pause", "stop", "reset", "release", "seek",
        "setVolume", "setSpeed", "setMediaSource",
        "CACHED_DURATION", "MEDIA_TYPE_AUD",
        "durationUpdate", "timeUpdate", "seekDone", "bufferingUpdate",
        "stateChange", "audioInterrupt", "audioOutputDeviceChangeWithInfo",
        "preferredBufferDuration", "mutedMediaType",
    ]),

    ("@ohos.multimedia.audio.d.ts", [
        "AudioRendererInfo", "StreamUsage", "STREAM_USAGE_MUSIC",
        "InterruptEvent", "InterruptHint", "InterruptForceType", "InterruptMode",
        "SHARE_MODE", "INDEPENDENT_MODE",
        "INTERRUPT_HINT_PAUSE", "INTERRUPT_HINT_STOP", "INTERRUPT_HINT_RESUME",
        "INTERRUPT_HINT_DUCK", "INTERRUPT_HINT_UNDUCK", "INTERRUPT_HINT_NONE",
        "INTERRUPT_FORCE", "INTERRUPT_SHARE",
        "AudioStreamDeviceChangeInfo", "getAudioManager", "getSessionManager",
    ]),

    ("@ohos.window.d.ts", [
        "setPreferredOrientation", "Orientation", "LANDSCAPE",
        "setWindowLayoutFullScreen", "setWindowSystemBarEnable",
        "setWindowSystemBarProperties", "SystemBarProperties",
        "getWindowAvoidArea", "AvoidAreaType", "TYPE_SYSTEM", "AvoidArea",
        "getMainWindowSync", "getWindowProperties", "windowRect",
        "setWindowKeepScreenOn", "Size", "WindowStage", "loadContent",
        "statusBarColor", "navigationBarColor", "statusBarContentColor",
        "navigationBarContentColor", "topRect", "bottomRect", "leftRect", "rightRect",
        "windowSizeChange",
    ]),

    ("@ohos.resourceschedule.backgroundTaskManager.d.ts", [
        "BackgroundMode", "AUDIO_PLAYBACK", "startBackgroundRunning",
        "stopBackgroundRunning", "ContinuousTaskCancelInfo",
        "continuousTaskCancel",
        # NOTE: `startBackgroundTask` / `BackgroundTaskMode` are deliberately NOT
        # asserted here: they do not exist in this API 23 declaration set, which
        # matches the documented fact that they are newer additions. The project
        # uses `startBackgroundRunning` + `BackgroundMode.AUDIO_PLAYBACK`, which
        # is the correct API for the API 14/15 target.
    ]),

    ("@ohos.data.preferences.d.ts", [
        "getPreferencesSync", "Options", "Preferences", "putSync", "getSync", "flush",
    ]),

    ("@ohos.file.fs.d.ts", [
        "openSync", "OpenMode", "READ_ONLY", "READ_WRITE", "CREATE", "TRUNC",
        "statSync", "readSync", "writeSync", "closeSync", "copyFileSync",
        "accessSync", "mkdirSync", "unlinkSync", "ReadOptions", "File", "size", "fd",
    ]),

    ("@ohos.file.picker.d.ts", [
        "DocumentViewPicker", "DocumentSelectOptions", "maxSelectNumber",
        "fileSuffixFilters", "select",
    ]),

    ("@ohos.util.d.ts", [
        "Base64Helper", "encodeToStringSync", "decodeSync",
        "TextDecoder", "create", "decodeToString",
        "TextEncoder", "encodeInto",
    ]),

    ("@ohos.display.d.ts", [
        "getDefaultDisplaySync", "densityPixels", "Display",
    ]),

    ("@ohos.app.ability.wantAgent.d.ts", [
        "getWantAgent", "WantAgentInfo", "OperationType", "START_ABILITY",
        "WantAgentFlags", "UPDATE_PRESENT_FLAG", "WantAgent",
    ]),

    ("@ohos.app.ability.common.d.ts", [
        "UIAbilityContext", "AbilityStageContext", "Context",
    ]),
    # NOTE: `Context.filesDir`, `Context.cacheDir` and `UIAbilityContext.abilityInfo`
    # are NOT in this declaration set: the SDK here ships only `ets/api` (432 files)
    # and omits the `api/application/**` subtree where Context/AbilityInfo live.
    # They were verified against the OpenHarmony docs instead, e.g.
    #   zh-cn/application-dev/media/media/playback-url-setting-method.md
    #   `let filePath = `${this.context.filesDir}/${...}`;`
    # and the background-task sample `context.abilityInfo.bundleName/.name`.
    # `BackgroundTaskKeeper.resolveTarget()` therefore also has a constants fallback.

    ("@ohos.app.ability.UIAbility.d.ts", [
        "UIAbility", "onCreate", "onDestroy", "onWindowStageCreate",
        "onWindowStageDestroy", "onForeground", "onBackground", "context",
    ]),

    ("@ohos.app.ability.AbilityStage.d.ts", [
        "AbilityStage", "onCreate", "onAcceptWant", "onDestroy",
    ]),

    ("@ohos.multimedia.image.d.ts", [
        "PixelMap",
    ]),
]


def load(name: str) -> str | None:
    path = API_DIR / name
    if not path.exists():
        return None
    return path.read_text(encoding="utf-8", errors="replace")


def main() -> int:
    if not API_DIR.exists():
        print(f"SDK declaration dir not found: {API_DIR}", file=sys.stderr)
        return 2

    missing_files: list[str] = []
    failures: list[str] = []
    checked = 0

    for fname, symbols in CHECKS:
        text = load(fname)
        if text is None:
            missing_files.append(fname)
            continue
        for sym in symbols:
            checked += 1
            # whole-word match; dotted names are checked by their last segment
            if not re.search(rf"(?<![\w$]){re.escape(sym)}(?![\w$])", text):
                failures.append(f"{fname}: `{sym}` NOT FOUND")

    print(f"declaration dir : {API_DIR}")
    print(f"files checked   : {len(CHECKS) - len(missing_files)}/{len(CHECKS)}")
    print(f"symbols checked : {checked}")

    if missing_files:
        print(f"\n=== MISSING DECLARATION FILES ({len(missing_files)}) ===")
        for f in missing_files:
            print("  " + f)

    if failures:
        print(f"\n=== SYMBOLS NOT FOUND ({len(failures)}) ===")
        for f in failures:
            print("  " + f)
        return 1

    print("\nall checked symbols exist in the SDK declarations")
    return 0


if __name__ == "__main__":
    sys.exit(main())
