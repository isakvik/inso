#version 460
// CRT-styled scalar postprocess, adapted from Timothy Lottes' public-domain [CRTS]
// (https://www.shadertoy.com/view/MtSfRK, RetroArch port by hunterk) for inso's post-pass
// pipeline. samples the src render target (PostParams.srcSlots.x); tunables come from UserParams.
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require

layout(binding = 4, std430) readonly buffer textureHandles {
    sampler2DArray textures[];
};
#else
uniform sampler2DArray textures[16];
#endif

layout(std140, binding = 14) uniform PostParams {
    uvec4 srcSlots;
};

layout(std140, binding = 3) uniform globalData {
    mat3 t;
    mat3 playfieldTransform;
    float time;
    float circleSizeOsupx;
    vec2 cursorPos;
    vec2 resolution;
};

// note: UserParams is shared across every post shader. the bloom composite already uses slot 0,
// so the CRT tunables start at slot 4. set them from lua with Shader.set_param(index, value).
layout(std140, binding = 7) uniform UserParams {
    vec4 params[16];
};
#define MASK              params[1].x // 0 none, 1 grille, 2 grille-lite, 3 shadow mask
#define MASK_INTENSITY    params[1].y // 0..1
#define SCANLINE_THINNESS params[1].z // 0 fused .. 1 thin
#define SCAN_BLUR         params[1].w // 1 sharp .. 3 blurry
#define CURVATURE         params[2].x // 0..0.25 barrel warp
#define TRINITRON_CURVE   params[2].y // 0 curved vertically, 1 flat
#define CORNER            params[2].z // 0..11 corner rounding
#define CRT_GAMMA         params[2].w // ~2.4
#define INPUT_SCALE       params[3].x // virtual input res as a fraction of output (e.g. 0.33)

in vec3 uv;
in vec4 color;
flat in uint texIndex;

out vec4 fragColor;

float FromSrgb1(float c) {
    return (c <= 0.04045) ? c * (1.0 / 12.92)
                          : pow(c * (1.0 / 1.055) + (0.055 / 1.055), CRT_GAMMA);
}
vec3 FromSrgb(vec3 c) { return vec3(FromSrgb1(c.r), FromSrgb1(c.g), FromSrgb1(c.b)); }

float ToSrgb1(float c) { return (c < 0.0031308) ? c * 12.92 : 1.055 * pow(c, 0.41666) - 0.055; }
vec3 ToSrgb(vec3 c) { return vec3(ToSrgb1(c.r), ToSrgb1(c.g), ToSrgb1(c.b)); }

#define CRTS_WARP 1
#define CRTS_TONE 1

vec3 CrtsFetch(vec2 p) {
    return FromSrgb(texture(textures[srcSlots.x], vec3(p, 0.0)).rgb);
}

float CrtsMax3(float a, float b, float c) { return max(a, max(b, c)); }

// tonal curve constants that renormalize the mid-level the scanlines + mask darken away
vec4 CrtsTone(float contrast, float saturation, float thin, float mask) {
    if (MASK == 0.0) mask = 1.0;
    if (MASK == 1.0) mask = 0.5 + mask * 0.5;

    float midOut = 0.18 / ((1.5 - thin) * (0.5 * mask + 0.5));
    float pMidIn = pow(0.18, contrast);

    vec4 ret;
    ret.x = contrast;
    ret.y = ((-pMidIn) + midOut) / ((1.0 - pMidIn) * midOut);
    ret.z = ((-pMidIn) * midOut + pMidIn) / (midOut * (-pMidIn) + midOut);
    ret.w = contrast + saturation;
    return ret;
}

vec3 CrtsMask(vec2 pos, float dark) {
    if (MASK == 2.0) {
        vec3 m = vec3(dark);
        float x = fract(pos.x * (1.0 / 3.0));
        if (x < 1.0 / 3.0)      m.r = 1.0;
        else if (x < 2.0 / 3.0) m.g = 1.0;
        else                    m.b = 1.0;
        return m;
    }
    if (MASK == 1.0) {
        vec3 m = vec3(1.0);
        float x = fract(pos.x * (1.0 / 3.0));
        if (x < 1.0 / 3.0)      m.r = dark;
        else if (x < 2.0 / 3.0) m.g = dark;
        else                    m.b = dark;
        return m;
    }
    if (MASK == 3.0) {
        pos.x += pos.y * 2.9999;
        vec3 m = vec3(dark);
        float x = fract(pos.x * (1.0 / 6.0));
        if (x < 1.0 / 3.0)      m.r = 1.0;
        else if (x < 2.0 / 3.0) m.g = 1.0;
        else                    m.b = 1.0;
        return m;
    }
    return vec3(1.0);
}

// 8-tap variant: 4 horizontal taps across each of the 2 nearest scanlines
vec3 CrtsFilter(
    vec2 ipos,
    vec2 inputSizeDivOutputSize,
    vec2 halfInputSize,
    vec2 rcpInputSize,
    vec2 rcpOutputSize,
    vec2 twoDivOutputSize,
    float inputHeight,
    vec2 warp,
    float thin,
    float blur,
    float mask,
    vec4 tone
) {
    vec2 pos;
#ifdef CRTS_WARP
    pos = ipos * twoDivOutputSize - vec2(1.0);
    pos *= vec2(1.0 + (pos.y * pos.y) * warp.x,
                1.0 + (pos.x * pos.x) * warp.y);
    float vin = (1.0 - ((1.0 - clamp(pos.x * pos.x, 0.0, 1.0)) * (1.0 - clamp(pos.y * pos.y, 0.0, 1.0))))
                * (0.998 + 0.001 * CORNER);
    vin = clamp((-vin) * inputHeight + inputHeight, 0.0, 1.0);
    pos = pos * halfInputSize + halfInputSize;
#else
    pos = ipos * inputSizeDivOutputSize;
#endif

    float y0 = floor(pos.y - 0.5) + 0.5;
    float x0 = floor(pos.x - 1.5) + 0.5;
    vec2 p = vec2(x0 * rcpInputSize.x, y0 * rcpInputSize.y);
    vec3 colA0 = CrtsFetch(p);
    p.x += rcpInputSize.x; vec3 colA1 = CrtsFetch(p);
    p.x += rcpInputSize.x; vec3 colA2 = CrtsFetch(p);
    p.x += rcpInputSize.x; vec3 colA3 = CrtsFetch(p);
    p.y += rcpInputSize.y; vec3 colB3 = CrtsFetch(p);
    p.x -= rcpInputSize.x; vec3 colB2 = CrtsFetch(p);
    p.x -= rcpInputSize.x; vec3 colB1 = CrtsFetch(p);
    p.x -= rcpInputSize.x; vec3 colB0 = CrtsFetch(p);

    float off = pos.y - y0;
    float pi2 = 6.28318530717958;
    float scanA = cos(min(0.5,  off  * thin       ) * pi2) * 0.5 + 0.5;
    float scanB = cos(min(0.5, (-off) * thin + thin) * pi2) * 0.5 + 0.5;

    float off0 = pos.x - x0;
    float off1 = off0 - 1.0;
    float off2 = off0 - 2.0;
    float off3 = off0 - 3.0;
    float pix0 = exp2(blur * off0 * off0);
    float pix1 = exp2(blur * off1 * off1);
    float pix2 = exp2(blur * off2 * off2);
    float pix3 = exp2(blur * off3 * off3);
    float pixT = 1.0 / (pix0 + pix1 + pix2 + pix3);
#ifdef CRTS_WARP
    pixT *= vin;
#endif
    scanA *= pixT;
    scanB *= pixT;

    vec3 color =
        (colA0 * pix0 + colA1 * pix1 + colA2 * pix2 + colA3 * pix3) * scanA +
        (colB0 * pix0 + colB1 * pix1 + colB2 * pix2 + colB3 * pix3) * scanB;

    color *= CrtsMask(ipos, mask);

#ifdef CRTS_TONE
    float peak = max(1.0 / (256.0 * 65536.0), CrtsMax3(color.r, color.g, color.b));
    vec3 ratio = color * (1.0 / peak);
    peak = peak * (1.0 / (peak * tone.y + tone.z));
    return ratio * peak;
#else
    return color;
#endif
}

#define INPUT_THIN (0.5 + 0.5 * SCANLINE_THINNESS)
#define INPUT_BLUR (-1.0 * SCAN_BLUR)
#define INPUT_MASK (1.0 - MASK_INTENSITY)

void main() {
    vec2 outputSize = resolution;
    vec2 inputSize  = max(floor(outputSize * INPUT_SCALE), vec2(1.0));

    vec2 warpFactor;
    warpFactor.x = CURVATURE;
    warpFactor.y = 0.75 * warpFactor.x; // assume 4:3
    warpFactor.x *= (1.0 - TRINITRON_CURVE);

    // ipos is output-space pixel coords built from uv (not gl_FragCoord) so CrtsFetch samples
    // the src target with the engine's v-flipped uv convention, matching the other post passes.
    vec2 ipos = uv.xy * outputSize;

    vec3 col = CrtsFilter(
        ipos,
        inputSize / outputSize,
        inputSize * 0.5,
        1.0 / inputSize,
        1.0 / outputSize,
        2.0 / outputSize,
        inputSize.y,
        warpFactor,
        INPUT_THIN,
        INPUT_BLUR,
        INPUT_MASK,
        CrtsTone(1.0, 0.0, INPUT_THIN, INPUT_MASK));

    fragColor = vec4(ToSrgb(col), 1.0);
}
