#[compute]
#version 450

layout(local_size_x = 512, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 3, std430) restrict buffer CameraData {
    mat4 ViewMatrix;
    float CameraFarPlane;
    float CameraNearPlane;
    vec2 _padding0;
    vec4 CameraWorldPosition;
}
camera_data;

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

layout(set = 1, binding = 0, std430) restrict buffer VerticesBuffer {
    float vertices[];
};

layout(set = 0, binding = 2, std430) buffer VisibleCounter {
    uint visible_count;
};

layout(set = 0, binding = 4, std430) buffer SortKeys {
    uvec2 sort_keys[];
};

layout(set = 0, binding = 5, std430) buffer ProjectedSplats {
    float projected_splats[];
};

const float SH_C0 = 0.28209479177387814;
const float SH_C1 = 0.4886025119029199;
const float SH_C2[5] = float[5](1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396);
const float SH_C3[7] = float[7](-0.5900435899266435, 2.890611442640554, -0.4570457994644658, 0.3731763325901154, -0.4570457994644658, 1.445305721320277, -0.5900435899266435);
const int NUM_PROPERTIES = 62;
const uint DEPTH_KEY_MAX = 65535u;
const float MIN_ALPHA = 1.0 / 255.0;

mat4 getProjectionMatrix(float aspect, float near, float far) {
    mat4 result = mat4(0.0);
    result[0][0] = 1.0 / (aspect * params.tan_fovy);
    result[1][1] = 1.0 / params.tan_fovy;
    result[2][2] = -(far + near) / (far - near);
    result[2][3] = -1.0;
    result[3][2] = -(2.0 * far * near) / (far - near);
    return result;
}

float sigmoid(float x) {
    if (x >= 0.0) {
        return 1.0 / (1.0 + exp(-x));
    }
    float z = exp(x);
    return z / (1.0 + z);
}

float ndc2Pix(float v, float size_px) {
    return ((v + 1.0) * size_px - 1.0) * 0.5;
}

vec3 computeColorFromSH(int deg, vec3 pos, vec3 cam_pos, vec3 sh[16]) {
    vec3 dir = normalize(pos - cam_pos);
    vec3 result = SH_C0 * sh[0];
    if (deg > 0) {
        float x = dir.x;
        float y = dir.y;
        float z = dir.z;
        result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];
        if (deg > 1) {
            float xx = x * x;
            float yy = y * y;
            float zz = z * z;
            float xy = x * y;
            float yz = y * z;
            float xz = x * z;
            result +=
                SH_C2[0] * xy * sh[4] +
                SH_C2[1] * yz * sh[5] +
                SH_C2[2] * (2.0 * zz - xx - yy) * sh[6] +
                SH_C2[3] * xz * sh[7] +
                SH_C2[4] * (xx - yy) * sh[8];
            if (deg > 2) {
                result +=
                    SH_C3[0] * y * (3.0 * xx - yy) * sh[9] +
                    SH_C3[1] * xy * z * sh[10] +
                    SH_C3[2] * y * (4.0 * zz - xx - yy) * sh[11] +
                    SH_C3[3] * z * (2.0 * zz - 3.0 * xx - 3.0 * yy) * sh[12] +
                    SH_C3[4] * x * (4.0 * zz - xx - yy) * sh[13] +
                    SH_C3[5] * z * (xx - yy) * sh[14] +
                    SH_C3[6] * x * (xx - 3.0 * yy) * sh[15];
            }
        }
    }
    result += 0.5;
    return max(result, 0.0);
}

mat3 computeCov3D(vec3 scale, vec4 rot) {
    mat3 S = mat3(
        vec3(params.modifier * exp(scale.x), 0.0, 0.0),
        vec3(0.0, params.modifier * exp(scale.y), 0.0),
        vec3(0.0, 0.0, params.modifier * exp(scale.z))
    );
    rot = normalize(rot);
    float r = rot.x;
    float x = rot.y;
    float y = rot.z;
    float z = rot.w;
    mat3 R = mat3(
        vec3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - r * z), 2.0 * (x * z + r * y)),
        vec3(2.0 * (x * y + r * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - r * x)),
        vec3(2.0 * (x * z - r * y), 2.0 * (y * z + r * x), 1.0 - 2.0 * (x * x + y * y))
    );
    mat3 M = S * R;
    return transpose(M) * M;
}

vec3 computeCov2D(vec3 position, vec3 log_scale, vec4 rot, mat4 viewMatrix) {
    mat3 cov3D = computeCov3D(log_scale, rot);
    vec4 t = viewMatrix * vec4(position, 1.0);
    float limx = 1.3 * params.tan_fovx;
    float limy = 1.3 * params.tan_fovy;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;
    mat4 J = mat4(
        vec4(params.focal_x / t.z, 0.0, -(params.focal_x * t.x) / (t.z * t.z), 0.0),
        vec4(0.0, params.focal_y / t.z, -(params.focal_y * t.y) / (t.z * t.z), 0.0),
        vec4(0.0, 0.0, 0.0, 0.0),
        vec4(0.0, 0.0, 0.0, 0.0)
    );
    mat4 W = transpose(viewMatrix);
    mat4 T = W * J;
    mat4 Vrk = mat4(
        vec4(cov3D[0][0], cov3D[0][1], cov3D[0][2], 0.0),
        vec4(cov3D[0][1], cov3D[1][1], cov3D[1][2], 0.0),
        vec4(cov3D[0][2], cov3D[1][2], cov3D[2][2], 0.0),
        vec4(0.0, 0.0, 0.0, 0.0)
    );
    mat4 cov = transpose(T) * transpose(Vrk) * T;
    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return vec3(cov[0][0], cov[0][1], cov[1][1]);
}

void writeInvalid(uint splat_index) {
    uint base = splat_index * 11u;
    for (uint i = 0u; i < 11u; i++) {
        projected_splats[base + i] = 0.0;
    }
}

void main() {
    uint splat_index = gl_GlobalInvocationID.x;
    if (splat_index >= uint(params.num_splats)) {
        return;
    }

    uint idx = splat_index * uint(NUM_PROPERTIES);
    float aspect = params.viewport_size.x / params.viewport_size.y;
    mat4 projMatrix = getProjectionMatrix(aspect, camera_data.CameraNearPlane, camera_data.CameraFarPlane);
    mat4 viewMatrix = camera_data.ViewMatrix;

    vec3 pos = vec3(vertices[idx], vertices[idx + 1u], vertices[idx + 2u]);
    vec4 clipSpace = projMatrix * viewMatrix * vec4(pos, 1.0);
    if (clipSpace.w <= 0.0) {
        writeInvalid(splat_index);
        return;
    }

    vec3 ndc = clipSpace.xyz / clipSpace.w;
    if (ndc.z < -1.0 || ndc.z > 1.0) {
        writeInvalid(splat_index);
        return;
    }

    vec3 scale = vec3(vertices[idx + 55u], vertices[idx + 56u], vertices[idx + 57u]);
    vec4 rot = vec4(vertices[idx + 58u], vertices[idx + 59u], vertices[idx + 60u], vertices[idx + 61u]);
    float opacity = sigmoid(vertices[idx + 54u]);
    if (opacity < MIN_ALPHA) {
        writeInvalid(splat_index);
        return;
    }

    vec3 cov2d = computeCov2D(pos, scale, rot, viewMatrix);
    float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    if (det <= 0.0) {
        writeInvalid(splat_index);
        return;
    }

    float det_inv = 1.0 / det;
    vec3 conic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
    float mid = 0.5 * (cov2d.x + cov2d.z);
    float lambda_term = max(0.1, mid * mid - det);
    float lambda_1 = mid + sqrt(lambda_term);
    float lambda_2 = mid - sqrt(lambda_term);
    float radius_px = ceil(3.0 * sqrt(max(lambda_1, lambda_2)));
    if (radius_px <= 0.0) {
        writeInvalid(splat_index);
        return;
    }

    vec2 point_image = vec2(ndc2Pix(-ndc.x, params.viewport_size.x), ndc2Pix(ndc.y, params.viewport_size.y));
    if (point_image.x + radius_px < 0.0 || point_image.x - radius_px > params.viewport_size.x || point_image.y + radius_px < 0.0 || point_image.y - radius_px > params.viewport_size.y) {
        writeInvalid(splat_index);
        return;
    }

    int degree = int(params.sh_degree);
    vec3 color;
    if (degree <= 0) {
        vec3 sh0 = vec3(vertices[idx + 6u], vertices[idx + 7u], vertices[idx + 8u]);
        color = max(SH_C0 * sh0 + 0.5, 0.0);
    } else {
        vec3 sh[16];
        uint coeff_index = idx + 6u;
        for (uint i = 0u; i < 16u; i++) {
            uint sh_offset = coeff_index + i * 3u;
            sh[i] = vec3(vertices[sh_offset], vertices[sh_offset + 1u], vertices[sh_offset + 2u]);
        }
        color = computeColorFromSH(degree, pos, camera_data.CameraWorldPosition.xyz, sh);
    }

    float depth01 = clamp(ndc.z * 0.5 + 0.5, 0.0, 1.0);
    uint depth_key = DEPTH_KEY_MAX - uint(round(depth01 * float(DEPTH_KEY_MAX)));

    uint base = splat_index * 11u;
    projected_splats[base + 0u] = point_image.x;
    projected_splats[base + 1u] = point_image.y;
    projected_splats[base + 2u] = radius_px;
    projected_splats[base + 3u] = color.r;
    projected_splats[base + 4u] = color.g;
    projected_splats[base + 5u] = color.b;
    projected_splats[base + 6u] = conic.x;
    projected_splats[base + 7u] = conic.y;
    projected_splats[base + 8u] = conic.z;
    projected_splats[base + 9u] = opacity;
    projected_splats[base + 10u] = 1.0;

    uint out_idx = atomicAdd(visible_count, 1u);
    sort_keys[out_idx] = uvec2(depth_key, splat_index);
}
