# sa3-on-device

An experiment: how much of sa3.cpp can an iPhone actually do? Inference and LoRA training,
in-process through `libsa3`, with no server.

This is an instrument, not a product. The UI exists to start a run and watch the numbers.

## Build

```sh
./scripts/build-libsa3.sh sim      # or: device, simx64
open SA3OnDevice.xcodeproj
```

`build-libsa3.sh` builds `~/sa3.cpp` for the chosen platform and stages the static archives into
`vendor/lib-<platform>/`. Xcode picks the right directory per SDK, so both can be staged at once.
Point `SA3_SRC` elsewhere if your checkout is not `~/sa3.cpp`.

## Models

The gguf set is ~1.5 GB at `small-music` / `q4_k_m`, too big to bundle, so it is side-loaded into
the app's Documents directory. The app expects:

```
Documents/models/     the gguf set (DiT, SAME, conditioner, encoder, vocab)
Documents/datasets/dataset/   a training dataset laid out as docs/TRAINING.md describes
```

Simulator:

```sh
DOCS=$(xcrun simctl get_app_container booted com.thecollabagepatch.sa3ondevice data)/Documents
mkdir -p "$DOCS/models"
cp ~/sa3.cpp/models/stable-audio-3-small-music-*.gguf "$DOCS/models/"
cp ~/sa3.cpp/models/t5gemma-b-b-ul2-*.gguf "$DOCS/models/"
```

Device: `UIFileSharingEnabled` is set, so drag the folders in through Finder or the Files app.

## Backends

| where | backend | notes |
|---|---|---|
| iPhone (A14+) | Metal | the point of the exercise |
| iPhone (A13 and older) | CPU | Metal `out_prod` needs simdgroup matrices; training refuses and says so |
| Simulator | **CPU, forced** | the simulator GPU reports `MTLGPUFamilyApple2` and traps in ggml's kernels |

`SA3Engine.device` forces `"cpu"` under `targetEnvironment(simulator)`. That makes the simulator
useful for everything except speed and memory: correctness, model loading, the UI, file handling.
It cannot tell you anything about Metal or about the per-app memory limit — the simulator reports
`recommendedMaxWorkingSetSize = 0` and has no jetsam.

## Layout

- `SA3Engine.swift` — Swift wrapper over the `libsa3` C ABI; the callbacks, threading, and WAV writing
- `ContentView.swift` — the controls and the log
- `SA3Bridge.h` — bridging header, just `#import "libsa3.h"`
