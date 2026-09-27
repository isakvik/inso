# glslang

Khronos reference GLSL validator, bundled so mapset shaders can be checked
for constructs that AMD/Intel reject but NVIDIA tolerates, without installing
anything.

- `linux/glslang` - built from source on Ubuntu 20.04 (glslang 16.5.0),
  static linkage, runs on old glibc boxes.
  Rebuild: install cmake >= 3.22, then
  `cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_SPVREMAPPER=OFF -DENABLE_OPT=OFF && make glslang-standalone`
- `windows/glslang.exe` - official CI build from the `main-tot` release:
  https://github.com/KhronosGroup/glslang/releases/tag/main-tot
- `LICENSE.txt` - glslang license (modified BSD-3), taken from the KhronosGroup/glslang repo.

Note: newer glslang releases name the validator binary `glslang` instead of
`glslangValidator`; stage is inferred from the file suffix, so validation is
done on temp copies renamed to `.vert` / `.frag`.
