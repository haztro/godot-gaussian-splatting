#[compute]

//VkRadixSort written by Mirco Werner: https://github.com/MircoWerner/VkRadixSort
// Based on implementation of Intel's Embree: https://github.com/embree/embree/blob/v4.0.0-ploc/kernels/rthwif/builder/gpu/sort.h

#version 460
#extension GL_GOOGLE_include_directive: enable

#define WORKGROUP_SIZE 512 // assert WORKGROUP_SIZE >= RADIX_SORT_BINS
#define RADIX_SORT_BINS 256

layout(local_size_x = WORKGROUP_SIZE, local_size_y = 1, local_size_z = 1) in;

layout (push_constant, std430) uniform PushConstants {
    uint g_num_elements;
    uint g_shift;
    uint g_num_workgroups;
    uint g_num_blocks_per_workgroup;
};

layout (std430, set = 0, binding = 0) buffer elements_in {  
    uvec2 g_elements_in[];
};

layout (std430, set = 0, binding = 1) buffer histograms {
    // [histogram_of_workgroup_0 | histogram_of_workgroup_1 | ... ]
    uint g_histograms[]; // |g_histograms| = RADIX_SORT_BINS * #WORKGROUPS
};

shared uint[RADIX_SORT_BINS] histogram;

void main() {
    uint gID = gl_GlobalInvocationID.x;
    uint lID = gl_LocalInvocationID.x;
    uint wID = gl_WorkGroupID.x;

    // initialize histogram
    if (lID < RADIX_SORT_BINS) {
        histogram[lID] = 0U;
    }
    barrier();

    for (uint index = 0; index < g_num_blocks_per_workgroup; index++) {
        uint elementId = wID * g_num_blocks_per_workgroup * WORKGROUP_SIZE + index * WORKGROUP_SIZE + lID;
        if (elementId < g_num_elements) {
            // determine the bin
            const uint bin = uint(g_elements_in[elementId][0] >> g_shift) & uint(RADIX_SORT_BINS - 1);
            // increment the histogram
            atomicAdd(histogram[bin], 1U);
        }
    }
    barrier();
    
    if (lID < RADIX_SORT_BINS) {
        g_histograms[RADIX_SORT_BINS * wID + lID] = histogram[lID];
    }
}