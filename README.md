# sa3.cpp-ios

**update 8/31:** thus far... training small-music on-device works at every level of
quantization on the iphone 13, and actually seems reasonable. attempting to pre-encode
latents with SAME-L, even the q4 variant, fails around the 5th track. it also takes
forever... inference is reasonable for medium, although kind of slow. it's fast as hell
for small-music. benchmarks incoming later.

Minimal iOS harness for on-device sa3 inference and LoRA training. Experiment, not a product.

Builds against sa3.cpp `feature/ios-build`. Run `./scripts/build-libsa3.sh sim` (or `device`), then open the xcodeproj.

Models side-load into `Documents/models/`; datasets into `Documents/datasets/dataset/`. Simulator forces the CPU backend — its GPU reports `MTLGPUFamilyApple2` and traps in ggml's Metal kernels.

## metal api validation

The shared scheme ships with Metal API Validation **off** (`enableGPUValidationMode = "1"`). Leave it off.

With it on, Run from Xcode aborts (SIGABRT) partway through SAME-S decode:

```
validateBuiltinArguments:974: failed assertion
`component 0: 98304 must be <= 65535 for tiitg [[ thread_index_in_threadgroup ]]'
```

It is a false positive. The rejected dispatch is `MUL_MAT` -> `kernel_mul_mm`, which ggml issues as
threadgroups `(2,1,768)` and threadsPerThreadgroup `(32,4,1)` — 128 threads, so `tiitg` tops out at
127, well inside `ushort`. 98304 is `768 * 128`: the grid's z extent times the threadgroup size, which
is not the range of a threadgroup-local index. Across one generation, 1 of 10509 dispatches crosses
that product — only SAME-S monolithic decode makes z large (`ne12*ne13 = 64*12`), every other dispatch
has `z = 1`, which is why nothing else trips it. Generation is correct with validation off.

To reproduce it outside Xcode (validation is an env var, not a debugger feature):

```bash
xcrun devicectl device process launch --device <udid> --console \
  --environment-variables '{"METAL_DEVICE_WRAPPER_TYPE":"1","GGML_METAL_GRAPH_DEBUG":"1"}' \
  com.thecollabagepatch.sa3ondevice
```
