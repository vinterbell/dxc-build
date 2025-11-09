struct SkyBoxRenderResources {
    uint positionBufferIndex;
    uint textureIndex;
    uint sceneBufferIndex;
};

struct VSOutput {
    float4 position : SV_Position;
    float4 modelSpacePosition : TEXCOORD0;
};

struct SceneBuffer {
    float4x4 viewProjectionMatrix;
};

ConstantBuffer<SkyBoxRenderResources> renderResource : register(b0);

SamplerState linearWrapSampler : register(s0);

VSOutput VsMain(uint vertexID : SV_VertexID)
{
    // StructuredBuffer<float3> positionBuffer = ResourceDescriptorHeap[renderResource.positionBufferIndex];
    StructuredBuffer<float3> positionBuffer = ResourceDescriptorHeap[renderResource.positionBufferIndex];
    ConstantBuffer<SceneBuffer> sceneBuffer = ResourceDescriptorHeap[renderResource.sceneBufferIndex];

    VSOutput output = (VSOutput)0;
    output.position = mul(float4(positionBuffer[vertexID], 0.0f), sceneBuffer.viewProjectionMatrix);
    output.modelSpacePosition = float4(positionBuffer[vertexID].xyz, 0.0f);
    output.position = output.position.xyww;

    return output;
}

float4 PsMain(VSOutput input) : SV_Target
{
    TextureCube environmentTexture = ResourceDescriptorHeap[renderResource.textureIndex];
    float3 samplingVector = normalize(input.modelSpacePosition.xyz);

    return environmentTexture.Sample(linearWrapSampler, samplingVector);
}