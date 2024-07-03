#[compute]
#version 450

// https://github.com/9ballsyndrome/WebGL_Compute_shader/tree/master/webgl-compute-bitonicSort

layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 3, std430) buffer DepthBuffer {
    uint depth[];
};

layout(set = 0, binding = 4, std430) buffer DepthIndexBuffer {
    uint depth_index[];
};

layout(push_constant) uniform NumElements {
    uvec4 numElements;
};


// The code we want to execute in each invocation
void main() {
    uint tmp;
    float tmp1;
    uint ixj = gl_GlobalInvocationID.x ^ numElements.y;
    if (ixj > gl_GlobalInvocationID.x) {
        if ((gl_GlobalInvocationID.x & numElements.x) == 0u) {
            if (depth[depth_index[gl_GlobalInvocationID.x]] < depth[depth_index[ixj]]) {
                tmp = depth_index[gl_GlobalInvocationID.x];
                depth_index[gl_GlobalInvocationID.x] = depth_index[ixj];
                depth_index[ixj] = tmp;
            }
        }
        else {
            if (depth[depth_index[gl_GlobalInvocationID.x]] > depth[depth_index[ixj]]) {
                tmp = depth_index[gl_GlobalInvocationID.x];
                depth_index[gl_GlobalInvocationID.x] = depth_index[ixj];
                depth_index[ixj] = tmp;
            }
        }
    }
}