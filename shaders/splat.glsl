#[vertex]
#version 450 core

layout(location = 0) in vec3 vertex_position;

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


layout(set = 0, binding = 0, std430) buffer DepthBuffer {
    uvec2 depth[];
};

layout(set = 1, binding = 0, std430) restrict buffer VerticesBuffer {
    float vertices[];
};


// Helpful resources:
// https://github.com/kishimisu/Gaussian-Splatting-WebGL
// https://github.com/antimatter15/splat
// https://github.com/graphdeco-inria/diff-gaussian-rasterization

const float SH_C0 = 0.28209479177387814;
const float SH_C1 = 0.4886025119029199;
const float SH_C2[5] = float[5](1.0925484305920792, -1.0925484305920792, 0.31539156525252005, -1.0925484305920792, 0.5462742152960396);
const float SH_C3[7] = float[7](-0.5900435899266435f, 2.890611442640554f, -0.4570457994644658f, 0.3731763325901154f, -0.4570457994644658f, 1.445305721320277f, -0.5900435899266435f);



vec3 computeColorFromSH(int deg, vec3 pos, vec3 cam_pos, vec3 sh[16]) {
	vec3 dir = normalize(pos - cam_pos);
	vec3 result = SH_C0 * sh[0];
	
    if (deg > 0) {
        float x = dir.x;
        float y = dir.y;
        float z = dir.z;
        result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

        if (deg > 1) {
            float xx = x * x, yy = y * y, zz = z * z;
            float xy = x * y, yz = y * z, xz = x * z;
            result = result +
                SH_C2[0] * xy * sh[4] +
                SH_C2[1] * yz * sh[5] +
                SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
                SH_C2[3] * xz * sh[7] +
                SH_C2[4] * (xx - yy) * sh[8];

            if (deg > 2) {
                result = result +
                    SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
                    SH_C3[1] * xy * z * sh[10] +
                    SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
                    SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
                    SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
                    SH_C3[5] * z * (xx - yy) * sh[14] +
                    SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
            }
        }
    }

	result += 0.5f;
	return max(result, 0.0f);
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

	mat3 Sigma = transpose(M) * M;
	
	return Sigma;
}



vec3 computeCov2D(vec3 position, vec3 log_scale, vec4 rot, mat4 viewMatrix, int idx) {
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



mat4 getProjectionMatrix(float aspect, float near, float far) {
    mat4 result = mat4(0.0);
    result[0][0] = 1.0 / (aspect * params.tan_fovy);
    result[1][1] = 1.0 / (params.tan_fovy);
    result[2][2] = -(far + near) / (far - near);
    result[2][3] = -1.0;
    result[3][2] = -(2.0 * far * near) / (far - near);
    return result;
}

float sigmoid(float x) {
    if (x >= 0.0) {
        return 1.0 / (1.0 + exp(-x));
    } else {
        float z = exp(x);
        return z / (1.0 + z);
    }
}


layout (location = 1) out vec3 vColor;
layout (location = 2) out vec2 vUV;
layout (location = 3) out vec4 vConicAndOpacity;

float ndc2Pix(float v, float S) {
    return ((v + 1.) * S - 1.) * .5;
}

const int NUM_PROPERTIES = 62;

void main()
{
    int idx = int(depth[gl_InstanceIndex][1]) * NUM_PROPERTIES;
    float aspect = params.viewport_size.x / params.viewport_size.y;
    mat4 projMatrix = getProjectionMatrix(aspect, camera_data.CameraNearPlane, camera_data.CameraFarPlane);
    mat4 viewMatrix = camera_data.CameraToWorld;

    // Projection
    vec3 pos = vec3(vertices[idx], vertices[idx + 1], vertices[idx + 2]);
    vec4 clipSpace = projMatrix * viewMatrix * vec4(pos, 1.0);
    float clip = 1.1 * clipSpace.w;
    float dist = clipSpace.z / clipSpace.w;
    depth[gl_InstanceIndex][0] = uint((1 - dist * 0.5 + 0.5) * 0xFFFF);


    if (clipSpace.z < -clip || clipSpace.z > clip || clipSpace.x < -clip || clipSpace.x > clip || clipSpace.y < -clip || clipSpace.y > clip) {
        gl_Position = vec4(0, 0, 2, 1);
        return;
    }
    
    vec3 scale = vec3(vertices[idx + 55], vertices[idx + 55 + 1], vertices[idx + 55 + 2]);
    vec4 rot = vec4(vertices[idx + 58], vertices[idx + 58 + 1], vertices[idx + 58 + 2], vertices[idx + 58 + 3]);
    float opacity = vertices[idx + 54];

    vec4 ndc = clipSpace / clipSpace.w;
    ndc.x *= -1; 

    vec3 cov2d = computeCov2D(pos, scale, rot, viewMatrix, idx);
	float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    if (det == 0.) {
        gl_Position = vec4(0, 0, 2, 1);
        return;
    }
	float det_inv = 1.0 / det;
	vec3 conic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
	float mid = 0.5 * (cov2d.x + cov2d.z);

    float lambda_1 = mid + sqrt(max(0.1, mid * mid - det));
    float lambda_2 = mid - sqrt(max(0.1, mid * mid - det));
    float radius_px = ceil(3. * sqrt(max(lambda_1, lambda_2)));
    vec2 point_image = vec2(ndc2Pix(ndc.x, params.viewport_size.x), ndc2Pix(ndc.y, params.viewport_size.y));

    vec3 sh[16];
    uint cidx = 0;
    uint index = idx + 6;
    for (int i = 0; i < 48; i += 3) {
        sh[cidx] = vec3(vertices[index + i], vertices[index + i + 1], vertices[index + i + 2]);
        cidx++;
    }

    vColor = computeColorFromSH(0, pos, vec3(viewMatrix[3].xyz), sh);  
    vConicAndOpacity = vec4(conic, sigmoid(opacity));

    vec2 screen_pos = point_image + radius_px * (vertex_position.xy);
    vUV = point_image - screen_pos;
    gl_Position = vec4(screen_pos / params.viewport_size * 2 - 1, 0, 1);
}



#[fragment]
#version 450 core

layout (location = 1) in vec3 vColor;
layout (location = 2) in vec2 vUV;
layout (location = 3) in vec4 vConicAndOpacity;
layout (location = 0) out vec4 frag_color;

void main()
{
    vec2 d = vUV;
    vec3 conic = vConicAndOpacity.xyz;
	float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;
	float opacity = vConicAndOpacity.w;
	
	if (power > 0.0) {
		discard;
	}

	float alpha = min(0.99, opacity * exp(power));
    vec3 color = vColor.rgb;

    if (alpha < 1.0/255.0) {
        discard;
    }

    frag_color = vec4(color * alpha, alpha);
}
