#[vertex]
#version 450 core

layout(location = 0) in vec3 vertex_position;

layout(set = 0, binding = 1, std430) restrict buffer Params {
    vec2 viewport_size;
    float tan_fovx;
    float tan_fovy;
    float focal_x;
    float focal_y;
    float modifier;
    float sh_degree;
    float num_splats;
}
params;

layout(set = 0, binding = 4, std430) buffer SortKeys {
    uvec2 sort_keys[];
};

layout(set = 0, binding = 5, std430) buffer ProjectedSplats {
    float projected_splats[];
};

layout(location = 1) out vec3 vColor;
layout(location = 2) out vec2 vUV;
layout(location = 3) out vec4 vConicAndOpacity;

void main() {
    uint splat_index = sort_keys[gl_InstanceIndex].y;
    uint base = splat_index * 11u;

    vec2 point_image = vec2(projected_splats[base + 0u], projected_splats[base + 1u]);
    float radius_px = projected_splats[base + 2u];
    vColor = vec3(projected_splats[base + 3u], projected_splats[base + 4u], projected_splats[base + 5u]);
    vConicAndOpacity = vec4(
        projected_splats[base + 6u],
        projected_splats[base + 7u],
        projected_splats[base + 8u],
        projected_splats[base + 9u]
    );

    vec2 screen_pos = point_image + radius_px * vertex_position.xy;
    vUV = point_image - screen_pos;
    gl_Position = vec4(screen_pos / params.viewport_size * 2.0 - 1.0, 0.0, 1.0);
}

#[fragment]
#version 450 core

layout(location = 1) in vec3 vColor;
layout(location = 2) in vec2 vUV;
layout(location = 3) in vec4 vConicAndOpacity;
layout(location = 0) out vec4 frag_color;

void main() {
    vec2 d = vUV;
    vec3 conic = vConicAndOpacity.xyz;
    float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;
    float opacity = vConicAndOpacity.w;
    if (power > 0.0) {
        discard;
    }

    float alpha = min(0.99, opacity * exp(power));
    if (alpha < 1.0 / 255.0) {
        discard;
    }

    frag_color = vec4(vColor * alpha, alpha);
}
