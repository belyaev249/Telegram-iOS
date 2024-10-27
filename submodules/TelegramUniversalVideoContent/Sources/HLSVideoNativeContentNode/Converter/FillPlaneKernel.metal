#include <metal_stdlib>
using namespace metal;

kernel void fillPlane(device unsigned char *dstPlane [[ buffer(0) ]],
                         const device unsigned char *srcPlane1 [[ buffer(1) ]],
                         const device unsigned char *srcPlane2 [[ buffer(2) ]],
                         const device unsigned int &srcPlaneSize [[ buffer(3) ]],
                         uint id [[ thread_position_in_grid ]]) {
    if (id > srcPlaneSize) { return; }
    uint i = id<<1;
    dstPlane[i] = srcPlane1[id];
    dstPlane[i+1] = srcPlane2[id];
}
