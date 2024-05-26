#[compute]
#version 450

// https://github.com/9ballsyndrome/WebGL_Compute_shader/tree/master/webgl-compute-bitonicSort

layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 7, std430) buffer DepthBuffer {
    uint depth[];
};


layout(set = 0, binding = 8, std430) buffer DepthIndexBuffer {
    uint depth_index[];
};


shared uint sharedIndices[1024];

// The code we want to execute in each invocation
void main() {

    // Load depths and initial indices uinto shared memory
    sharedIndices[gl_LocalInvocationID.x] = depth_index[gl_GlobalInvocationID.x];

    memoryBarrierShared();
    barrier();

    uint offset = gl_WorkGroupID.x * gl_WorkGroupSize.x;
    
    // Bitonic sort
    for (uint k = 2u; k <= gl_WorkGroupSize.x; k <<= 1) {
        for (uint j = k >> 1; j > 0u; j >>= 1) {
            uint ixj = (gl_GlobalInvocationID.x ^ j) - offset;
            if (ixj > gl_LocalInvocationID.x) {
                if ((gl_GlobalInvocationID.x & k) == 0u) {
                    if (depth[sharedIndices[gl_LocalInvocationID.x]] < depth[sharedIndices[ixj]]) {
                        uint tmpIndex = sharedIndices[gl_LocalInvocationID.x];
                        sharedIndices[gl_LocalInvocationID.x] = sharedIndices[ixj];
                        sharedIndices[ixj] = tmpIndex;
                    }
                } else {
                    if (depth[sharedIndices[gl_LocalInvocationID.x]] > depth[sharedIndices[ixj]]) {
                        uint tmpIndex = sharedIndices[gl_LocalInvocationID.x];
                        sharedIndices[gl_LocalInvocationID.x] = sharedIndices[ixj];
                        sharedIndices[ixj] = tmpIndex;
                    }
                }
            }
            memoryBarrierShared();
            barrier();
        }
    }

    depth_index[gl_GlobalInvocationID.x] = sharedIndices[gl_LocalInvocationID.x];
}