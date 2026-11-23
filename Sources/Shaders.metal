#include <metal_stdlib>
using namespace metal;

struct SceneVertexIn {
    float3 position [[attribute(0)]];
    float2 uv       [[attribute(1)]];
};

struct FrameUniforms {
    float4x4 viewProj;
};

struct DrawUniforms {
    float4x4 model;
};

struct SceneVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex SceneVertexOut scene_vertex(SceneVertexIn in [[stage_in]],
                                   constant FrameUniforms &frame [[buffer(1)]],
                                   constant DrawUniforms &draw [[buffer(2)]]) {
    SceneVertexOut out;
    out.position = frame.viewProj * draw.model * float4(in.position, 1.0);
    out.uv = in.uv;
    return out;
}

// O shader original do Quest só lê RGB e escreve alpha 1.0.
fragment float4 scene_fragment(SceneVertexOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler smp [[sampler(0)]]) {
    float3 c = tex.sample(smp, in.uv).rgb;
    return float4(c, 1.0);
}

struct HandVertex {
    float4 position;
    float4 color;
};

struct HandOut {
    float4 position [[position]];
    float4 color;
};

vertex HandOut hand_vertex(uint vid [[vertex_id]],
                           constant HandVertex *verts [[buffer(0)]],
                           constant float4x4 &proj [[buffer(1)]]) {
    HandOut out;
    out.position = proj * verts[vid].position;
    out.color = verts[vid].color;
    return out;
}

fragment float4 hand_fragment(HandOut in [[stage_in]]) {
    return in.color;
}

// ---------------------------------------------------------------------------
// Mão translúcida (estilo Quest): silhueta desenhada como campo de distância.
// Dados em `D` (buffer 0), tudo em pixels do quadro:
//   D[0] = viewport (x, y, largura, altura)
//   D[1].x = quantidade de mãos
//   D[2 + h*24 + i]  i = 0...20: pontos da mão h (xy)
//   D[2 + h*24 + 21] = (pinça 0/1, tamanho da palma em px, 0, 0)
//   D[2 + h*24 + 22] = caixa (minx, miny, maxx, maxy)
// ---------------------------------------------------------------------------

struct HandFSOut {
    float4 position [[position]];
};

vertex HandFSOut handsdf_vertex(uint vid [[vertex_id]]) {
    float2 t = float2(float((vid << 1) & 2), float(vid & 2));
    HandFSOut o;
    o.position = float4(t * 2.0 - 1.0, 0.0, 1.0);
    return o;
}

static float sdCone(float2 p, float2 a, float2 b, float ra, float rb) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-4), 0.0, 1.0);
    return length(pa - ba * h) - mix(ra, rb, h);
}

static float smin2(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0) / k;
    return min(a, b) - h * h * k * 0.25;
}

// distância (em px) até a silhueta da mão; `armFade` fica < 1 na região do antebraço
static float handDist(float2 p, constant float4 *D, int base, thread float &armFade) {
    float S = max(D[base + 21].y, 8.0);
    float2 P[21];
    for (int i = 0; i < 21; i++) {
        P[i] = D[base + i].xy;
    }

    // palma: polígono (pulso, base do polegar, 4 nós dos dedos) engordado
    float2 V[6] = { P[0], P[1], P[5], P[9], P[13], P[17] };
    float dd = dot(p - V[0], p - V[0]);
    float sgn = 1.0;
    for (int i = 0, j = 5; i < 6; j = i, i++) {
        float2 e = V[j] - V[i];
        float2 w = p - V[i];
        float2 b = w - e * clamp(dot(w, e) / max(dot(e, e), 1e-4), 0.0, 1.0);
        dd = min(dd, dot(b, b));
        bool3 c = bool3(p.y >= V[i].y, p.y < V[j].y, e.x * w.y > e.y * w.x);
        if (all(c) || !any(c)) { sgn = -sgn; }
    }
    float d = sgn * sqrt(dd) - 0.15 * S;
    float k = 0.07 * S;

    // dedos: polegar 1-2-3-4, indicador 5-6-7-8, médio 9-..., anelar 13-..., mínimo 17-...
    for (int f = 0; f < 5; f++) {
        int s = (f == 0) ? 1 : (5 + (f - 1) * 4);
        float rf = (f == 0) ? 1.05 : ((f == 4) ? 0.82 : 1.0);
        for (int j = 0; j < 3; j++) {
            float ra = S * rf * (0.170 - 0.012 * float(j));
            float rb = S * rf * (0.170 - 0.012 * float(j + 1));
            float dc = sdCone(p, P[s + j], P[s + j + 1], ra, rb);
            d = smin2(d, dc, k);
        }
    }

    // antebraço: prolonga o pulso para fora da mão e some aos poucos
    float2 dir = P[0] - P[9];
    float dl = max(length(dir), 1e-3);
    dir = dir / dl;
    float armLen = 1.1 * S;
    float dArm = sdCone(p, P[0], P[0] + dir * armLen, 0.16 * S, 0.19 * S);
    float t = clamp(dot(p - P[0], dir) / armLen, 0.0, 1.0);
    float fadeVal = 1.0 - smoothstep(0.15, 1.0, t);
    float w = smoothstep(0.0, 0.10 * S, d - dArm);
    armFade = mix(1.0, fadeVal, w);
    d = smin2(d, dArm, k);
    return d;
}

fragment float4 handsdf_fragment(HandFSOut in [[stage_in]],
                                 constant float4 *D [[buffer(0)]]) {
    float2 p = in.position.xy;
    float count = D[1].x;
    float4 acc = float4(0.0);

    for (int h = 0; h < 2; h++) {
        if (float(h) >= count) { break; }
        int base = 2 + h * 24;
        float4 bb = D[base + 22];
        if (p.x < bb.x || p.y < bb.y || p.x > bb.z || p.y > bb.w) { continue; }

        float S = max(D[base + 21].y, 8.0);
        float pinch = D[base + 21].x;
        float fade = 1.0;
        float d = handDist(p, D, base, fade);

        float lw = max(1.6, 0.011 * S);
        float inside = 1.0 - smoothstep(-1.0, 1.0, d);
        float outline = 1.0 - smoothstep(lw * 0.4, lw * 1.3, abs(d));
        float rim = exp(min(d, 0.0) / (0.09 * S));
        float fillA = inside * (0.06 + 0.20 * rim);
        float outer = (1.0 - inside) * exp(-max(d, 0.0) / (0.03 * S)) * 0.10;
        float a = clamp(outline * 0.95 + fillA + outer, 0.0, 1.0) * fade;

        float3 col = mix(float3(0.96, 0.98, 1.0), float3(0.55, 0.85, 1.0), pinch * 0.6);
        // "over" em alfa pré-multiplicado
        acc.rgb = acc.rgb * (1.0 - a) + col * a;
        acc.a = acc.a * (1.0 - a) + a;
    }

    if (acc.a < 0.004) { discard_fragment(); }
    return float4(acc.rgb / max(acc.a, 1e-4), acc.a);
}
