#version 450

#pragma parameter GAIN "Gain" 0.5 0.0 1.0 0.1
layout(push_constant) uniform Push {
    mat4 MVP;
    float GAIN;
    vec4 OutputSize;
    vec4 OriginalSize;
    vec4 SourceSize;
} params;

#pragma stage vertex
layout(location = 0) in vec4 Position;
layout(location = 1) in vec2 TexCoord;
layout(location = 0) out vec2 vTexCoord;

void main() {
    gl_Position = params.MVP * Position;
    vTexCoord = TexCoord;
}

#pragma stage fragment
layout(location = 0) in vec2 vTexCoord;
layout(location = 0) out vec4 FragColor;
layout(set = 0, binding = 2) uniform sampler2D Source;

vec3 applyGain(vec3 color, float gain) {
    return color * gain;
}

void main() {
    vec4 color = texture(Source, vTexCoord);
    FragColor = vec4(applyGain(color.rgb, params.GAIN), color.a);
}
