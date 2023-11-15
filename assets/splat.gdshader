shader_type spatial;
render_mode unshaded, cull_disabled, skip_vertex_transform;

uniform float tan_fovx;
uniform float tan_fovy;
uniform float focal_x;
uniform float focal_y;
uniform float modifier;
uniform float transparent_thresh;
uniform int sh_degree;

uniform sampler2D data;
uniform sampler2D sh_data;
uniform int tex_width;

const float SH_C0 = 0.28209479177387814;
const float SH_C1 = 0.4886025119029199;
const float SH_C2[5] = float[5] (
	1.0925484305920792,
	-1.0925484305920792,
	0.31539156525252005,
	-1.0925484305920792,
	0.5462742152960396
);
const float SH_C3[7] = float[7] (
	-0.5900435899266435f,
    2.890611442640554f,
    -0.4570457994644658f,
    0.3731763325901154f,
    -0.4570457994644658f,
    1.445305721320277f,
    -0.5900435899266435f
);

vec3 computeColorFromSH(int deg, vec3 pos, vec3 cam_pos, vec3 sh[16]) {
	// The implementation is loosely based on code for 
	// "Differentiable Point-Based Radiance Fields for 
	// Efficient View Synthesis" by Zhang et al. (2022)
	vec3 dir = normalize(pos - cam_pos);
	vec3 result = SH_C0 * sh[0];
	
//	if (deg > 0) {
	float x = dir.x;
	float y = dir.y;
	float z = dir.z;
	result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];
//		if (deg > 1) {
	float xx = x * x, yy = y * y, zz = z * z;
	float xy = x * y, yz = y * z, xz = x * z;
	result = result +
		SH_C2[0] * xy * sh[4] +
		SH_C2[1] * yz * sh[5] +
		SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
		SH_C2[3] * xz * sh[7] +
		SH_C2[4] * (xx - yy) * sh[8];
//			if (deg > 2) {
	result = result +
		SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
		SH_C3[1] * xy * z * sh[10] +
		SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
		SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
		SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
		SH_C3[5] * z * (xx - yy) * sh[14] +
		SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
//			}
//		}
//	}
	result += 0.5f;
	return max(result, 0.0f);
}


mat3 computeCov3D(vec3 scale, vec4 rot) {
	mat3 S = mat3(
		vec3(modifier * exp(scale.x), 0.0, 0.0),
		vec3(0.0, modifier * exp(scale.y), 0.0),
		vec3(0.0, 0.0, modifier * exp(scale.z))
	);

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

vec3 computeCov2D(vec3 position, vec3 log_scale, vec4 rot, mat4 viewMatrix) {
    mat3 cov3D = computeCov3D(log_scale, rot);

    vec4 t = viewMatrix * vec4(position, 1.0);

    float limx = 1.3 * tan_fovx;
    float limy = 1.3 * tan_fovy;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;

    mat4 J = mat4(
        vec4(focal_x / t.z, 0.0, -(focal_x * t.x) / (t.z * t.z), 0.0),
        vec4(0.0, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z), 0.0),
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

float sigmoid(float x) {
    if (x >= 0.0) {
        return 1.0 / (1.0 + exp(-x));
    } else {
        float z = exp(x);
        return z / (1.0 + z);
    }
}

varying vec4 conic_and_opacity;

void vertex() {
	int pos_index = INSTANCE_ID * 3;
	int scale_index = pos_index + 1;
	int rot_index = pos_index + 2;
	int x = pos_index % tex_width;
	int y = pos_index / tex_width;
	vec3 pos = texelFetch(data, ivec2(x, y), 0).xyz;
	
	x = scale_index % tex_width;
	y = scale_index / tex_width;
	vec4 o_scale = texelFetch(data, ivec2(x, y), 0);

	x = rot_index % tex_width;
	y = rot_index / tex_width;
	vec4 rot = texelFetch(data, ivec2(x, y), 0);

	vec3 cov2d = computeCov2D(pos, o_scale.yzw, rot, MODELVIEW_MATRIX);
	float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
	float det_inv = 1.0 / det;
	vec3 conic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
	float mid = 0.5 * (cov2d.x + cov2d.z);

    float lambda_1 = mid + sqrt(max(0.1, mid * mid - det));
    float lambda_2 = mid - sqrt(max(0.1, mid * mid - det));
    float radius_px = ceil(3. * sqrt(max(lambda_1, lambda_2)));
	vec2 radius_ndc = vec2(radius_px / (VIEWPORT_SIZE.x), radius_px / (VIEWPORT_SIZE.y)); 

    conic_and_opacity = vec4(conic, sigmoid(o_scale.x));

	vec2 uv = (2.0 * UV - 1.0);
	vec4 projPosition = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(pos, 1.0);
	projPosition = projPosition / projPosition.w;
	POSITION = vec4(projPosition.xy + 2.0 * radius_ndc * uv, projPosition.zw);

	int sh_index = INSTANCE_ID * 16;
	vec3 shs[16];
	for (int i = 0; i < 16; i++) {
		x = (sh_index+i) % tex_width;
		y = (sh_index+i) / tex_width;
		shs[i] = texelFetch(sh_data, ivec2(x, y), 0).rgb;
	}
	
	COLOR.rgb = computeColorFromSH(3, pos, CAMERA_POSITION_WORLD, shs);
	UV = radius_px * uv;

}

void fragment() {
	vec2 d = -UV;
	vec3 conic = conic_and_opacity.xyz;
	float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;
	float opacity = conic_and_opacity.w;
	
//	if (power > 0.0) {
//		discard;
//	}

	float alpha = min(0.99, opacity * exp(power));
	
	// Since godot doesn't have OIT just get rid of the transparent frags
	if (alpha < transparent_thresh) {
		discard;
	}
	
	ALBEDO = COLOR.rgb * alpha;
//	ALPHA = alpha;
}
