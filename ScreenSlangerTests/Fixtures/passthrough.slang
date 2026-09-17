float4 shaderFunction(ShaderInput input) {
    return input.sample(input.texCoord);
}
