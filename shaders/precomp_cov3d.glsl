#[compute]
#version 450 core

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

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


layout(set = 0, binding = 0, std430) buffer DepthBuffer {
    uvec2 depth[];
};


layout(set = 0, binding = 2, std430) restrict buffer VerticesBuffer {
    float vertices[];
};


layout(set = 0, binding = 5, std430) buffer Cov3dBuffer {
    float precomp_cov3d[];
};


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

	mat3 Sigma = transpose(M) * M;
	
	return Sigma;
}

const int NUM_PROPERTIES = 62;

void main()
{
    
    int idx = int(gl_GlobalInvocationID.x) * NUM_PROPERTIES;
    vec3 scale = vec3(vertices[idx + 55], vertices[idx + 55 + 1], vertices[idx + 55 + 2]);
    vec4 rot = vec4(vertices[idx + 58], vertices[idx + 58 + 1], vertices[idx + 58 + 2], vertices[idx + 58 + 3]);

    mat3 cov3d = computeCov3D(scale, rot);
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 0] = cov3d[0][0];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 1] = cov3d[0][1];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 2] = cov3d[0][2];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 3] = cov3d[1][0];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 4] = cov3d[1][1];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 5] = cov3d[1][2];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 6] = cov3d[2][0];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 7] = cov3d[2][1];
    precomp_cov3d[gl_GlobalInvocationID.x * 9 + 8] = cov3d[2][2];

    depth[2 * gl_GlobalInvocationID.x] = uvec2(0, gl_GlobalInvocationID.x);

}
