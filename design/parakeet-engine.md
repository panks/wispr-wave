# WisprWave: Parakeet engine support — design

Oct 9, 2026 · Pankaj

**Status: implemented on branch `parakeet-engine`.** Sections below are updated to match what was built; points found during implementation are marked *Implemented*.

## Summary

WisprWave on macOS gets a second speech engine, NVIDIA Parakeet TDT 0.6B (v2 and v3), run on the Neural Engine through the FluidAudio Swift package, beside the existing Whisper engine. The menu-bar popup gets a Whisper | Parakeet switch above the model list; switching engines unloads the old model and loads the last-used model of the new one. Whisper stays the default.

**Goals**

- Offer Parakeet v2 (English, most accurate for English) and v3 (25 European languages) as downloadable models.
- Let the user switch engines from the popup in one click, with only one model in memory at a time.
- Keep everything that is engine-independent working unchanged: hotkey, Legacy Mode, auto-stop, the HUD and text injection.
- Keep the app building in full Swift 6 language mode.

**Non-goals (for this change)**

- Boost Mode (live streaming transcription) with Parakeet. Boost is greyed out while Parakeet is active.
- Replacing the energy-based auto-stop detector with Silero VAD, even though FluidAudio ships one.
- Changes to the Linux port, which already uses Parakeet v2 through sherpa-onnx.
- Making Parakeet the default engine.

## Background: the app today

The Mac app is built around WhisperKit end to end; there is no engine abstraction to plug Parakeet into yet. The pieces this change touches:

| Component | What it does today | Whisper-specific? |
| --- | --- | --- |
| `ModelManager` | Scans `~/Library/Application Support/WisprWave/Models`, downloads models with `WhisperKit.download`, loads one `WhisperKit` instance, transcribes, remembers the last-used model under `WisprWave.LastUsedModel` | Yes, entirely |
| `ModelManager.transcribe(stream:)` | Boost Mode: re-transcribes the growing buffer about once a second using `clipTimestamps` and segment confirmation | Yes, relies on Whisper decoding options |
| `ModelsConfig` | Static list of about 10 Whisper Core ML models (id, name, Hugging Face URL) | Yes |
| `AppState` | Hotkey start/stop, HUD, text injection, `isProcessing` guard; persists Legacy, Boost and auto-stop settings | Only through `ModelManager` |
| `AudioRecorder` | Records 16 kHz mono float samples (memory) or a WAV file (Legacy); auto-stop with WhisperKit's `EnergyVAD` | Only `EnergyVAD` |
| `ContentView` | Menu-bar popup: ON/OFF, status line, model list with download and power buttons, hotkey, Legacy, Boost, auto-stop, Quit | Model list only |
| `SettingsView` | A standard Settings window that nothing can open | Dead code, deleted first |

The audio format is already what Parakeet expects (16 kHz, mono, Float32), so recording does not change. WhisperKit stays a dependency: it remains the Whisper engine and still provides `EnergyVAD` for auto-stop.

## Decisions

| Decision | Choice | Reason |
| --- | --- | --- |
| Parakeet models | v2 and v3 | v2 is the most accurate for English (about 6.05% average WER vs about 6.3% for v3 and 7.4% for Whisper large-v3); v3 adds 25 European languages |
| Default engine | Whisper | Existing users keep their setup; Parakeet is opt-in |
| Old model on engine switch | Unloaded | See below |
| Boost Mode under Parakeet | Greyed out with a tooltip | Boost's streaming code depends on Whisper decoding options; Parakeet is expected to be fast enough to transcribe the whole recording at stop |
| Where the engine switch lives | Menu-bar popup only | The Settings window is unreachable and is deleted in its own commit first |
| Inference library | FluidAudio | Native Swift, ships Core ML builds of both Parakeet versions, runs on the Neural Engine, supports macOS 14+ like the app |

**Why the old model is unloaded on switch.** Only one engine can transcribe at a time, so a second loaded model only costs memory. Whisper large-v3 and Parakeet are each several hundred MB of weights, and the Neural Engine is shared between them. Unloading also keeps the state simple: there is always exactly one active model, which is what the status line and power buttons already assume. The cost is a reload when switching back, which the existing "Loading …" status already covers; switching engines is expected to be rare.

> **Open point (resolved):** this assumed Parakeet is fast enough without Boost. It is: in the test harness on an M4 Max, a 4.9 s clip transcribes in about 0.05 s and a 29 s clip in about 0.13 s. Parakeet streaming stays out of scope.

## UI design

The popup gains one control: a segmented Whisper | Parakeet switch between the status line and the model list. It selects the active engine, not just a filter, so the switch, the list and the status line always agree.

Popup mock-up with Parakeet active:

```
        ┌────────────────────────────────────┐
        │              [  ON  ]              │
        │    Using: Parakeet v2 (English)    │
        ├────────────────────────────────────┤
        │      [ Whisper | *Parakeet* ]      │ ← Engine switch: sets the active engine
        │ Parakeet v2 (English)       [↓] [●]│ ← This engine's models only;
        │ Parakeet v3 (25 languages)  [↓] [○]│ ←   power loads, as today
        ├────────────────────────────────────┤
        │     Hotkey: [ Opt + Cmd + X ]      │
        │ [ ] Legacy Mode (VMs)  [-] Boost   │ ← Boost greyed out (tooltip: not needed)
        │ [ ] Auto-stop after [5s] of silence│
        │              [ Quit ]              │
        └────────────────────────────────────┘
```

Key: `[↓]` download, `[●]` power (loaded), `[○]` power (not loaded), `[-]` disabled checkbox.

Everything below the model list is today's popup; under Parakeet only the Boost checkbox changes.

*Implemented:* with nothing loaded, the status line reads "Download a Parakeet model" when the engine has no downloaded model, or "Select a Parakeet model" when one is on disk but not loaded. During an engine switch, before the new model is named, it reads "Loading...".

**Engine switch behaviour**

1. The user picks the other engine.
2. The current model is unloaded and the status line shows "Loading \<model\>…".
3. The last-used model of the new engine is loaded. If that engine has no downloaded model, nothing is loaded and the status line shows "Download a Parakeet model" (or Whisper).
4. The list redraws with only the new engine's models.

The switch is disabled while dictating or transcribing (`isListening` or `isProcessing`) and while a download is running, so a model is never swapped under an active transcription.

**Model rows** keep today's design: name, download button, power button. Parakeet rows read "Parakeet v2 (English)" and "Parakeet v3 (25 languages)". Pressing power on a row in the visible list loads that model, as today.

**Options under the list**

| Control | Whisper | Parakeet |
| --- | --- | --- |
| Hotkey | as today | as today |
| Legacy Mode (VMs) | as today | as today: records to a file, then the file's samples go to Parakeet |
| Boost | as today | greyed out, tooltip "Not needed with Parakeet" |
| Auto-stop | as today | as today |

Greying out Boost rather than hiding it matches how Boost already behaves under Legacy Mode and keeps the popup the same size for both engines. The user's Boost preference is kept and applies again on switching back to Whisper.

## Architecture

`ModelManager` stays the one object the UI and `AppState` talk to, but the speech work moves behind a small engine interface with two implementations. Everything above `ModelManager` keeps calling the same methods.

```
┌────────────────────┐  samples  ┌────────────────────────┐   ┌──────────────────────┐
│ AudioRecorder      │ ────────▶ │ AppState               │   │ Menu-bar popup       │
│ 16 kHz mono samples│           │ hotkey, HUD, injection │   │ engine switch        │
│ EnergyVAD auto-stop│           │ Boost only with Whisper│   │ model list per engine│
└────────────────────┘           └───────────┬────────────┘   └──────────┬───────────┘
                                             │ transcribe(samples)       │
                                             ▼                           │
                                 ┌────────────────────────────┐          │
                                 │ ModelManager               │ ◀────────┘
                                 │ catalog, downloads, switch │
                                 │ last-used model per engine │
                                 └─────────────┬──────────────┘
                                               │ one engine loaded at a time
                         ┌─────────────────────┴─────────────────────┐
                         ▼                                           ▼
            ┌──────────────────────────┐             ┌──────────────────────────────┐
            │ WhisperEngine            │             │ ParakeetEngine (new)         │
            │ WhisperKit, Core ML      │             │ FluidAudio AsrManager actor  │
            │ batch and Boost streaming│             │ Parakeet v2 / v3, batch only │
            └────────────┬─────────────┘             └──────────────┬───────────────┘
                         ▼                                          ▼
            ┌────────────────────────────────────────────────────────────────────────┐
            │ Models folder: ~/Library/Application Support/WisprWave/Models          │
            └────────────────────────────────────────────────────────────────────────┘
```

The popup and `AppState` only ever call `ModelManager`; which engine answers is decided there.

**New types**

```swift
enum SpeechEngine: String, Codable, CaseIterable {
    case whisper, parakeet
}

@MainActor
protocol TranscriptionEngine: AnyObject {
    var kind: SpeechEngine { get }
    func transcribe(samples: [Float]) async throws -> String
    func unload() async
}
```

| Type | Wraps | Responsibilities |
| --- | --- | --- |
| `WhisperEngine` | one `WhisperKit` instance | Today's load config (tokenizer redirect, prewarm), batch transcription, and the Boost streaming method `transcribe(stream:)`, which stays Whisper-only |
| `ParakeetEngine` | one FluidAudio `AsrManager` actor + its `AsrModels` | Load a v2 or v3 model folder, transcribe with a fresh `TdtDecoderState` per dictation, release models with `cleanup()` |
| `ModelManager` | the active `TranscriptionEngine?` | Model catalog, downloads, scanning, load/unload, engine switching, last-used model per engine, the published state the UI reads |

**FluidAudio calls `ParakeetEngine` relies on** (verified against the pinned v0.17.4):

- `AsrModels.download(to:force:version:encoderPrecision:progressHandler:)` downloads a model. The folder passed is not used as-is: FluidAudio resolves it to `<parent>/<repo folderName>` (see Models, downloads and storage).
- `AsrModels.loadLocal(from:version:encoderPrecision:)` loads a downloaded folder without touching the network; `AsrManager(config: .default)` + `loadModels(_:)` prepares it. `AsrModels.load(from:)` is not used, because it can fall back to downloading.
- `AsrModels.modelsExist(at:version:encoderPrecision:)` checks a folder. It only checks that the top-level bundles exist, which an interrupted download can already satisfy.
- `AsrManager.transcribe(_ samples: [Float], decoderState: inout TdtDecoderState)` returns `ASRResult`, whose `text` is the transcript. It rejects clips shorter than 0.3 s (`ASRConstants.minimumRequiredSamples`).
- `AsrManager.cleanup()` releases the models.
- `AsrModelVersion.v2` / `.v3` select the model; `Repo.parakeetV2` / `.parakeetV3` give the folder names. The encoder precision is fixed at `.int8` (v2 has a single encoder), and download, existence check and load all pass the same value.

**ModelsConfig** gains an engine field. `ModelInfo` becomes `id`, `name`, `engine`, plus an optional Hugging Face `url` used only by Whisper models. *Implemented:* Parakeet entries carry no version; `ParakeetEngine` holds the one map from catalog id to `AsrModelVersion` and `Repo`. The popup shows `visibleModels`, the catalog filtered by the active engine.

**What does not change:** `AudioRecorder` (including `EnergyVAD` auto-stop), the HUD, `TextInjector`, the hotkey service, and `AppState`'s start/stop flow apart from the Boost check.

## Models, downloads and storage

Parakeet models are downloaded by FluidAudio into the same folder as the Whisper models, so all model files stay in one place, as the May tokenizer fix intended.

| Model | Catalog id | Folder under `Models/` | FluidAudio version |
| --- | --- | --- | --- |
| Parakeet v2 (English) | `parakeet-tdt-0.6b-v2` | `parakeet-tdt-0.6b-v2/` | `.v2` |
| Parakeet v3 (25 languages) | `parakeet-tdt-0.6b-v3` | `parakeet-tdt-0.6b-v3/` | `.v3` |

`Models/` is `~/Library/Application Support/WisprWave/Models`, as today.

**Folder semantics.** FluidAudio treats the folder it is given as `<parent>/<something>` and always uses `<parent>/<repo folderName>`. The repo folder names equal our catalog ids, so passing `Models/<id>` to `download`, `loadLocal` and `modelsExist` lands in exactly `Models/<id>`. `ParakeetEngine.version(for:)` asserts that each id matches its repo's folder name.

**Download.** The download button calls `AsrModels.download(to: Models/<id>, …)`. FluidAudio's default cache directory is never used. Sizes as fetched: about 464 MB for v2 and 483 MB for v3. The Hugging Face repos are read from `main`, so the model files are not pinned by the FluidAudio version.

**Progress.** FluidAudio reports one repo download (bytes over all files as 0…0.5, then compiling as 0.5…1), followed by three cached loads that each restart at 0.5. Only the byte phase is real progress, so `ParakeetEngine` stretches it ×2 to 0…1 and holds the bar at its high-water mark for everything else; `ModelManager` also never moves the bar backwards. The status reads "Downloading \<model\> (N%)…" while bytes are transferring and "Preparing \<model\>…" otherwise, which covers the roughly 14 s compile after the bytes arrive.

**Detecting downloaded models.** `scanModels()` already treats each folder name under `Models/` as a model id, so the Parakeet folders show up without new code. A Parakeet folder only counts as downloaded if it holds a `.wisprwave-complete` marker, written after `download` returns, *and* `AsrModels.modelsExist(at:)` passes, so an interrupted download is offered again. If the bundles exist but the marker does not, the next download passes `force: true` so FluidAudio fetches everything again instead of skipping.

**Cancel.** Cancelling cancels the download task and deletes the partial model folder; a failed download deletes it too. FluidAudio does stop promptly, but surfaces cancellation as `NSURLError` -999 (cancelled) rather than `CancellationError`, so `ModelManager` checks `Task.isCancelled` instead of the error type. A new download waits for a cancelled one to finish deleting its folder before it starts.

**First load.** Core ML compiles a model the first time it is loaded. FluidAudio does this at the end of the download, so the cost (about 14 s) is paid during "Preparing \<model\>…", not at first load. Later loads take about 0.1 s.

## Engine switching and model lifecycle

At most one model is loaded at any time, and every load goes through one `ModelManager` method that unloads first.

**`switchEngine(to:)`**

1. Ignore the call if the engine is already active, or if `isListening`, `isProcessing`, `isDownloading` or a load is in progress.
2. Save the new engine as `WisprWave.ActiveEngine`.
3. Unload the current engine: `await engine.unload()`, then clear `currentModelName` and `isModelLoaded`.
4. Look up `WisprWave.LastUsedModel.<engine>`. If that model is downloaded, load it; otherwise stay unloaded and show "Download a \<engine\> model".

**`loadModel(name:)`** (power button and step 4 above) keeps its current contract but becomes engine-aware: it looks up the model's engine in the catalog, unloads whatever is loaded (even a model of the same engine), creates the matching `WhisperEngine` or `ParakeetEngine`, loads it, and records it as that engine's last-used model.

**At launch**, `loadLastUsedModel()` loads the last-used model of the saved active engine, which is Whisper for anyone who has never switched.

**Guards against overlap**

- A new `isLoadingModel` flag disables the engine switch and all power buttons while a load is running, so two loads never race.
- The existing `isProcessing` guard already stops a new dictation while one is transcribing; the switch is disabled in that state too, so a model is never unloaded mid-transcription.
- `startListening()` already refuses to start when no model is loaded, which covers the window between unload and load.

**Load failure** leaves nothing loaded, clears that engine's last-used entry and shows "Couldn't load \<model\>" in the status line. The user can press power to retry or switch back.

*Implemented:* `switchEngine(to:)` holds `isLoadingModel` while unloading. `ModelManager` cannot see `isListening` or `isProcessing`, so the popup's disable rules (switch and power buttons) are what keep a swap from landing under a dictation.

## Transcription flow per mode

With Parakeet active, every dictation takes the existing whole-recording path: record, stop, transcribe the full buffer once, hide the HUD, inject the text. Only the Boost branch needs a code change.

| Mode | Whisper (unchanged) | Parakeet |
| --- | --- | --- |
| Standard (memory recording) | Full buffer to `WhisperKit.transcribe` at stop | Full buffer to `AsrManager.transcribe` at stop |
| Boost | Live re-transcription while recording, short final pass at stop | Not available: falls through to Standard |
| Legacy Mode | 16 kHz mono WAV, read back to samples, transcribed at stop | Same WAV and samples, sent to Parakeet |
| Auto-stop | `EnergyVAD` on the live samples calls `stopListening()` | Same, engine-independent |

**The one code change in `AppState`.** `startListening()` starts the Boost streaming task when `!isLegacyMode && isBoostMode`. That condition gains `&& modelManager.activeEngine == .whisper`. With no streaming task, `stopListening()` already takes the whole-buffer branch, which calls `modelManager.transcribe(audioSamples:)`; that method now forwards to the active engine.

**Per-dictation state.** `ParakeetEngine` creates a fresh `TdtDecoderState` for each call, so nothing carries over between dictations.

**Very short clips.** FluidAudio rejects audio under 0.3 s; `ParakeetEngine` returns empty text instead of throwing. *Implemented:* an empty transcript now shows "No speech detected" in every path. Before this change, only the Boost path did; the Standard and Legacy paths showed "Done: " and injected nothing.

**Long dictations.** FluidAudio splits audio longer than its model window (about 15 s, per its source) into chunks internally, so no chunking is needed in the app.

## Settings and migration

Two new UserDefaults keys and a rename of one existing key; existing users see no change until they switch engines.

| Key | Type | Default | Notes |
| --- | --- | --- | --- |
| `WisprWave.ActiveEngine` | `whisper` or `parakeet` | `whisper` | New |
| `WisprWave.LastUsedModel.whisper` | model id | migrated | Takes the value of today's `WisprWave.LastUsedModel` |
| `WisprWave.LastUsedModel.parakeet` | model id | none | New |
| `WisprWave.IsBoostMode` | Bool | unchanged | Kept as is; Parakeet ignores it without changing it |

**Migration** runs once in `ModelManager.init`: if `WisprWave.LastUsedModel` exists and `WisprWave.LastUsedModel.whisper` does not, copy it across and remove the old key. Every saved Whisper model id is still valid, so nothing else moves.

**Model files** need no migration: Whisper folders stay where they are, and Parakeet folders are added beside them.

## Concurrency and Swift 6

FluidAudio is written for Swift 6, and Parakeet fits the app's full Swift 6 mode without the workarounds WhisperKit needed (confirmed by building).

- **`AsrManager` is an actor, but reentrant.** Calls into it can be made from the main actor without data-race errors, but it awaits inside `transcribe`, so two concurrent transcriptions could interleave, and a `cleanup()` that runs mid-transcribe makes that transcription throw. The app prevents both: the `isProcessing` guard allows one dictation at a time, the popup disables the engine switch and power buttons while dictating or transcribing, and `ParakeetEngine.unload()` skips `cleanup()` while a transcription is in flight (it just drops its reference, and the models are freed when that transcription finishes).
- **`AsrModels.loadLocal` is synchronous** and opens four Core ML models, so `ParakeetEngine` calls it from a `@concurrent nonisolated` helper to keep it off the main actor. `download` runs the same way.
- **The types crossing the boundary are `Sendable`**: `ASRResult`, `TdtDecoderState` and `AsrModelVersion` are declared `Sendable` in the v0.17.4 source.
- **`TdtDecoderState` is passed `inout`.** `ParakeetEngine.transcribe` keeps it as a local `var` inside the method, which is allowed across an actor boundary; it is never stored on the engine.
- **`ParakeetEngine` and `WhisperEngine` are `@MainActor`,** like `ModelManager` today, so engine switching and published UI state stay on the main thread.
- **`WhisperEngine` keeps `@preconcurrency import WhisperKit`** from the earlier Swift 6 fix; nothing changes there.
- **FluidAudio package settings:** swift-tools-version 6.0, macOS 14 minimum, matching the app. Pinned with `exact: "0.17.4"` (tag `v0.17.4`). It is not dependency-free: it links a prebuilt `NemoTextProcessing` xcframework (a Rust static library from FluidInference/text-processing-rs).

## Error handling and edge cases

| Situation | Behaviour |
| --- | --- |
| Switch to an engine with no downloaded model | Nothing loads; status "Download a \<engine\> model"; the hotkey shows the existing "Model Not Loaded" status |
| Download fails or is cancelled | Partial folder deleted; status shows the error; the row's download button is enabled again |
| Model folder deleted or corrupted on disk | `modelsExist(at:)` fails at scan, so the row shows as not downloaded; a load attempt fails as below |
| Load fails | Nothing loaded; that engine's last-used entry cleared; status "Couldn't load \<model\>" |
| Transcription throws | Existing handling: the error goes into the status, the HUD hides, no text is injected |
| Empty transcript (silence, or a clip under 0.3 s) | "No speech detected", nothing injected, in every mode |
| Hotkey pressed while a model loads | Existing guard: refused with "Model Not Loaded" |
| Engine switch while dictating, transcribing, downloading or loading | Switch is disabled |
| App quits during a Parakeet download | Existing `cancelDownload()` on terminate also cancels the Parakeet task; the partial folder fails `modelsExist` next launch and is offered again |
| v3 on English speech | Works; v2 is preferred for English accuracy, which the row names make clear |

## Testing plan

The project has no automated tests, so verification is a clean Swift 6 build, a small command-line harness that downloads, loads and transcribes with `ParakeetEngine` (used for the timings in this doc), code review, and a manual checklist run on the packaged app. Items marked *(build)*, *(harness)* or *(code review)* were verified that way; unchecked items still need the manual checklist on the packaged app.

**Build**

- [x] `./package_app.sh` builds with no errors in Swift 6 mode *(build)*
- [x] No new warnings from FluidAudio usage *(build)*

**Engine switching**

- [ ] Fresh settings: Whisper is active and the last Whisper model loads at launch
- [ ] Existing settings: the previously used Whisper model still loads (migration)
- [ ] Switch to Parakeet with nothing downloaded: Whisper unloads, status asks for a download
- [ ] Switch back to Whisper: the last Whisper model reloads
- [ ] Switch is disabled while dictating, transcribing, downloading and loading *(disable rules confirmed by code review; still to try in the app)*
- [ ] Memory drops after switching away from a loaded model (Activity Monitor)

**Parakeet models**

- [x] Download v2 and v3 into `Models/<id>`: sizes, folder layout and monotonic progress *(harness)*
- [ ] Download v2 and v3 in the app: progress bar moves, then "Preparing…", folders appear under `Models/`
- [x] Cancelling stops the download promptly (NSURLError -999) *(harness)*
- [ ] Cancel a download midway in the app: partial folder removed, download offered again
- [x] Load from disk with no network; transcribe 4.9 s and 29 s clips correctly; clips under 0.3 s return empty text *(harness)*
- [ ] Load v2, dictate a few English sentences, text is injected correctly
- [ ] Load v3, dictate in English and one other European language
- [ ] Dictate for over a minute: full transcript, no dropped middle
- [ ] Relaunch: the last Parakeet model loads if Parakeet was active

**Modes with Parakeet**

- [ ] Boost is greyed out with its tooltip; the saved Boost setting returns on switching back to Whisper
- [ ] Legacy Mode dictation works
- [ ] Auto-stop ends a dictation after the set silence
- [ ] HUD shows the spinner and hides cleanly; no crash on macOS 27

**Accuracy spot check**

- [ ] Read the same three paragraphs with Whisper large-v3 and Parakeet v2; compare the errors

## Implementation plan

Seven commits on a `parakeet-engine` branch, each building and leaving the app usable, merged to `main` after the testing checklist passes. All seven are done:

1. **Done (`5db7fc0`). Delete the unused Settings window.** Remove `SettingsView.swift` and the `Settings { … }` scene in `WisprWaveApp.swift`. No behaviour change.
2. **Done (`524df22`). Add FluidAudio and verify its API (Phase 0).** Add the package pinned with `exact:` to a release at least two weeks old (0.17.4, from 25 Sep 2026, at the time of writing; 0.17.7 came out on 8 Oct). Build in Swift 6 mode and confirm the calls listed under Architecture, the download folder layout and cancellation. Update this doc where reality differs. *Pinned 0.17.4; the differences are folded into this doc.*
3. **Done (`8629bfc`). Extract `WhisperEngine`.** Introduce `SpeechEngine` and `TranscriptionEngine`, and move today's WhisperKit code out of `ModelManager` into `WhisperEngine`. Whisper behaviour must be identical; test Standard, Boost and Legacy dictation.
4. **Done (`d85fdf4`). Engine-aware catalog and settings.** Add `engine` to `ModelInfo`, the Parakeet entries, `WisprWave.ActiveEngine`, last-used model per engine with the one-time migration, `switchEngine(to:)` and `isLoadingModel`.
5. **Done (`60f88b9`). Add `ParakeetEngine`.** Download into `Models/`, `modelsExist` checks in `scanModels()`, load, transcribe, unload, cancel.
6. **Done (`1c46267`). UI.** Segmented engine switch, list filtered by engine, Parakeet row names, Boost greyed out with its tooltip, the disable rules, and the Boost gate in `startListening()`.
7. **Done (this commit). Docs.** README section on choosing an engine and credits; this doc updated to match the implementation. The release note is still to write.

Commits 3 and 6 carry the most risk: 3 because it moves working Whisper code, 6 because it is the first time a user can reach Parakeet.

## Risks and open questions

**Risks**

| Risk | Mitigation |
| --- | --- |
| FluidAudio changes fast: eight releases between 21 Sep and 8 Oct 2026, and its README already differs from its source (`transcribe` now takes a decoder state) | Pinned exactly at 0.17.4; API verified; upgrade deliberately |
| The Parakeet Hugging Face repos track `main`, not a FluidAudio version, so a new download could fetch changed model files | Accepted for now; the download path and `.wisprwave-complete` marker don't depend on file contents |
| Extracting `WhisperEngine` breaks working Whisper behaviour, especially Boost | Commit 3 changes no behaviour and is tested on its own before Parakeet is added |
| Recorder quality limits Parakeet's accuracy. Memory recording turns 48 kHz into 16 kHz by keeping every third sample of the first channel, with no low-pass filter (`AudioRecorder.swift` line 254), which can alias high frequencies into the speech band | Affects both engines today. Fix separately with `AVAudioConverter` if the accuracy spot check disappoints |
| First Parakeet load is slow while Core ML compiles the model | FluidAudio compiles at the end of the download (about 14 s, shown as "Preparing…"); later loads take about 0.1 s |

**Open questions**

- [x] Download size of each Parakeet model as FluidAudio fetches it: about 464 MB for v2 and 483 MB for v3.
- [x] Does `AsrModels.download(to:)` treat the folder as the model folder or as a parent it creates a subfolder in? As a child of its parent: it uses `<parent>/<repo folderName>`, which equals our catalog id (see Models, downloads and storage).
- [x] Does FluidAudio stop a download promptly when its task is cancelled? Yes, with `NSURLError` -999 rather than `CancellationError`.
- [x] Licence terms of the Parakeet v2 and v3 Core ML builds, for the README: CC-BY-4.0 (NVIDIA models, Core ML conversions by FluidInference). FluidAudio itself is Apache-2.0. Both are credited in the README.
- [ ] Future: FluidAudio now also offers newer Parakeet variants (`redux`, which needs macOS 15+, and `ultra`, which its README recommends for multilingual use). Worth a later look; out of scope here.

## Sources

- [FluidAudio (GitHub)](https://github.com/FluidInference/FluidAudio)
- [FluidInference/parakeet-tdt-0.6b-v2-coreml (Hugging Face)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml)
- [FluidInference/parakeet-tdt-0.6b-v3-coreml (Hugging Face)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [Parakeet vs Whisper vs Nemotron: Best Local STT 2026 (OpenWhispr)](https://openwhispr.com/blog/parakeet-vs-whisper-vs-nemotron)
- [Open ASR Leaderboard paper (arXiv 2510.06961)](https://arxiv.org/html/2510.06961v4)
