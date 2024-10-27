#include <metal_stdlib>
using namespace metal;

struct VertexIn
{
    float4 pos [[attribute(0)]];
    float2 uv [[attribute(1)]];
};

struct VertexOut {
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
};

vertex VertexOut mapTexture(VertexIn input [[stage_in]]) {
    VertexOut outVertex;
    outVertex.renderedCoordinate = input.pos;
    outVertex.textureCoordinate = input.uv;
    return outVertex;
}

fragment half4 displayTexture(VertexOut mappingVertex [[ stage_in ]],
                              texture2d<half, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

fragment half4 displayYUVTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> yTexture [[ texture(0) ]],
                                  texture2d<half> uTexture [[ texture(1) ]],
                                  texture2d<half> vTexture [[ texture(2) ]],
                                  sampler textureSampler [[ sampler(0) ]])
{
    float3x3 yuvToBGRMatrix = float3x3(float3(1.0, 1.0, 1.0),
                                   float3(0.0, -0.18732, 1.8556),
                                   float3(1.57481, -0.46813, 0.0));
    half3 yuv;
    yuv.x = yTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.y = uTexture.sample(textureSampler, in.textureCoordinate).r;
    yuv.z = vTexture.sample(textureSampler, in.textureCoordinate).r;
    return half4(half3x3(yuvToBGRMatrix)*yuv, 1);
}

fragment half4 displayNV12Texture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]])
{
    half4 luminance = lumaTexture.sample(textureSampler, in.textureCoordinate);
    half4 chrominance = chromaTexture.sample(textureSampler, in.textureCoordinate);
    half3 yuv = half3(luminance[0], chrominance[0] - 0.5, chrominance[1] - 0.5);
    half3 rgb;
    rgb.r = yuv.x + yuv.z * 1.57;
    rgb.g = yuv.x - 0.18 * yuv.y - 0.46 * yuv.z;
    rgb.b = yuv.x + 1.85 * yuv.y;
    
    return half4(rgb, 1);
}

half3 shaderLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(4096.0/(2523 * 128)));
    rgb = max(rgb - half3(3424./4096), 0.0) / (half3(2413./4096 * 32) - half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(4096.0 * 4 / 2610));
    return rgb;
}

half3 shaderDeLinearize(half3 rgb) {
    rgb = pow(max(rgb,0), half3(2610./4096 / 4));
    rgb = (half3(3424./4096) - half3(2413./4096 * 32) * rgb) / (half3(1.0) + half3(2392./4096 * 32) * rgb);
    rgb = pow(rgb, half3(2523./4096 * 128));
    return rgb;
}

fragment half4 displayYCCTexture(VertexOut in [[ stage_in ]],
                                  texture2d<half> lumaTexture [[ texture(0) ]],
                                  texture2d<half> chromaTexture [[ texture(1) ]],
                                  sampler textureSampler [[ sampler(0) ]])
{
    half3 ipt;
    ipt.x = lumaTexture.sample(textureSampler, in.textureCoordinate).r;
    ipt.yz = chromaTexture.sample(textureSampler, in.textureCoordinate).rg;
    half3x3 ipt2lms = half3x3{{1, 799/8192, 1681/8192}, {1, -933/8192, 1091/8192}, {1, 267/8192, -5545/8192}};
    half3x3 lms2rgb = half3x3{{3.43661, -0.79133, -0.0259499}, {-2.50645, 1.98360, -0.0989137}, {0.06984, -0.192271, 1.12486}};
    half3 lms = ipt2lms*ipt;
    lms = shaderLinearize(lms);
    half3 rgb = lms2rgb*lms;
    rgb = shaderDeLinearize(rgb);
    return half4(rgb, 1);
}
