// A simple test shader for Slang in ScreenShader

float4 shaderFunction(ShaderInput input) {
    // Sample the input texture
    float4 color = input.sample(input.texCoord);
    
    // Create a simple wave effect based on time
    float wave = sin(input.screenPosition.x * 0.02 + input.time * 2.0) * 0.5 + 0.5;
    
    // Tint the color based on the wave
    color.rgb *= float3(wave, 1.0 - wave * 0.5, 1.0);
    
    return color;
}