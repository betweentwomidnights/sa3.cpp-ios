# sa3.cpp-ios

Minimal iOS harness for on-device sa3 inference and LoRA training. Experiment, not a product.

Builds against sa3.cpp `feature/ios-build`. Run `./scripts/build-libsa3.sh sim` (or `device`), then open the xcodeproj.

Models side-load into `Documents/models/`; datasets into `Documents/datasets/dataset/`. Simulator forces the CPU backend — its GPU reports `MTLGPUFamilyApple2` and traps in ggml's Metal kernels.
