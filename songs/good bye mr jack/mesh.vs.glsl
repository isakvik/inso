#version 460
#ifdef BINDLESS
#extension GL_ARB_bindless_texture : require
#extension GL_NV_gpu_shader5 : enable
#endif

// note: matches the tightly-packed Odin Mesh_Vertex (pos/norm/uv, 32 bytes). declaring vec3
// members here would pad to std430 16-byte alignment and desync from the cpu layout, so we
// spell the fields out as scalar floats.
struct Vertex {
    float px, py, pz;
    float nx, ny, nz;
    float u, v;
};

layout(binding = 1, std430) readonly buffer vertexData {
    Vertex vertices[];
};
layout (binding = 3, std140) uniform globalData {
    mat3 t;
    mat3 playfieldTransform;
    float time;
    float circleSizeOsupx;
    vec2 cursorPos;
    vec2 resolution;
};

out vec3 norm;
out vec2 uv;

mat3 rotateY(float a) {
    float c = cos(a), s = sin(a);
    return mat3(c, 0, -s, 0, 1, 0, s, 0, c);
}
mat3 rotateX(float a) {
    float c = cos(a), s = sin(a);
    return mat3(1, 0, 0, 0, c, s, 0, -s, c);
}

void main() {
    Vertex vert = vertices[gl_VertexID];
    vec3 pos = vec3(vert.px, vert.py, vert.pz);
    vec3 nrm = vec3(vert.nx, vert.ny, vert.nz);

    mat3 model = rotateY(time * 0.0011) * rotateX(time * 0.0007);
    vec3 world = model * pos;
    world.z -= 4.0; // push the unit cube in front of the camera at the origin

    norm = model * nrm;
    uv = vec2(vert.u, vert.v);

    float aspect = resolution.x / resolution.y;
    float f = 1.0 / tan(radians(45.0) * 0.5);
    // note: keep near/far tight around the model so depth precision isn't wasted on empty space.
    // the mesh renders into its own depth-cleared target, so it only ever competes with itself.
    float near = 1.0, far = 20.0;

    // right-handed perspective, looking down -z
    gl_Position = vec4(
        world.x * f / aspect,
        world.y * f,
        world.z * (far + near) / (near - far) + (2.0 * far * near) / (near - far),
        -world.z);
}
