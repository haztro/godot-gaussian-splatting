#[compute]
#version 450

layout(local_size_x = 512, local_size_y = 1, local_size_z = 1) in;


layout(set = 0, binding = 3, std430) restrict buffer CameraData {
	mat4 CameraToWorld;
	float CameraFarPlane;
	float CameraNearPlane;
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
}
params;

layout(set = 1, binding = 0, std430) restrict buffer VerticesBuffer {
    float vertices[];
};

layout(set = 0, binding = 2) buffer Counter {
    uint visible_count;
};

// Output splats
layout(set = 0, binding = 4) buffer VisibleSplats {
    uvec2 visible_splats[];
};


mat4 getProjectionMatrix(float aspect, float near, float far) {
    mat4 result = mat4(0.0);
    result[0][0] = 1.0 / (aspect * params.tan_fovy);
    result[1][1] = 1.0 / (params.tan_fovy);
    result[2][2] = -(far + near) / (far - near);
    result[2][3] = -1.0;
    result[3][2] = -(2.0 * far * near) / (far - near);
    return result;
}


const int NUM_PROPERTIES = 62;

void main()
{
    uint idx = gl_GlobalInvocationID.x * NUM_PROPERTIES;
    float aspect = params.viewport_size.x / params.viewport_size.y;
    mat4 projMatrix = getProjectionMatrix(aspect, camera_data.CameraNearPlane, camera_data.CameraFarPlane);
    mat4 viewMatrix = camera_data.CameraToWorld;

    // Projection
    vec3 pos = vec3(vertices[idx], vertices[idx + 1], vertices[idx + 2]);
    vec4 clipSpace = projMatrix * viewMatrix * vec4(pos, 1.0);
    float clip = 1.1 * clipSpace.w;
    float dist = clipSpace.z / clipSpace.w;

    if (clipSpace.z < -clip || clipSpace.z > clip || clipSpace.x < -clip || clipSpace.x > clip || clipSpace.y < -clip || clipSpace.y > clip) {
        return;
    }

    uint out_idx = atomicAdd(visible_count, 1);
    visible_splats[out_idx] = uvec2(uint((1 - dist * 0.5 + 0.5) * 0xFFFF), gl_GlobalInvocationID.x);
}


