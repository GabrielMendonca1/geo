import Foundation

enum MacDuoShader {
    static let source = #"""
    #include <metal_stdlib>
    using namespace metal;
    struct MacDuoUniformsMSL { float progress; float perspective; float blur; float shadow; float2 size; float fadeOnly; uint effect; };
    struct Varying { float4 position [[position]]; float2 uv; };

    vertex Varying foldVertex(uint id [[vertex_id]]) {
        const float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};
        Varying v;
        v.position = float4(p[id],0,1);
        v.uv = float2((p[id].x+1)*0.5f,1-(p[id].y+1)*0.5f);
        return v;
    }

    kernel void foldDownsample(texture2d<float, access::sample> source [[texture(0)]],
                               texture2d<float, access::write> target [[texture(1)]],
                               uint2 pixel [[thread_position_in_grid]]) {
        if (pixel.x >= target.get_width() || pixel.y >= target.get_height()) return;
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float2 uv = (float2(pixel)+0.5f)/float2(target.get_width(),target.get_height());
        float2 texel = 1.0f/float2(source.get_width(),source.get_height());
        const float offset[3] = {-1.2f,0,1.2f};
        const float weight[3] = {0.3125f,0.375f,0.3125f};
        float4 color = 0;
        for (uint y=0;y<3;y++) for (uint x=0;x<3;x++)
            color += source.sample(s,uv+float2(offset[x],offset[y])*texel)*weight[x]*weight[y];
        target.write(color,pixel);
    }

    static float3 foldSample(texture2d<float> desktop, texture2d<float> pyramid,
                             sampler s, float2 uv, float sigmaUV) {
        if (!(sigmaUV > 0.0f)) return desktop.sample(s,uv).rgb;
        float sigma = sigmaUV*float(desktop.get_height());
        float lod = 0.5f*log2(1.0f+sigma*sigma*2.4f);
        lod = min(lod,float(pyramid.get_num_mip_levels()-1));
        return pyramid.sample(s,uv,level(lod)).rgb;
    }

    static float4 foldRoll(float2 uv, texture2d<float> desktop, texture2d<float> pyramid,
                           sampler s, constant MacDuoUniformsMSL& u, float p) {
        float persp = clamp(u.perspective,0.0f,1.0f);
        float soft = clamp(u.blur,0.0f,1.0f);
        float shad = clamp(u.shadow,0.0f,1.0f);
        float h = 1.0f-uv.y;
        float thickness = 0.028f+0.055f*persp;
        float tangent = 1.0f-p;
        float radius = sqrt(0.0001f+thickness*p/M_PI_F);
        float feather = 0.0022f+0.004f*soft;

        float edgeAngle = clamp((1.0f-tangent)/max(radius,1e-5f),M_PI_F*0.5f,M_PI_F*1.5f);
        float lowest = min(tangent,tangent+radius*sin(edgeAngle));

        float3 plane = desktop.sample(s,uv).rgb;
        plane *= 1.0f-shad*0.5f*exp(-max(0.0f,lowest-h)/(0.05f+0.05f*soft));
        float3 color = plane*smoothstep(0.0f,feather,tangent-h);

        float k = clamp((h-tangent)/max(radius,1e-5f),-1.0f,1.0f);
        float theta = M_PI_F-asin(k);
        float arc = tangent+radius*theta;
        float facing = max(abs(cos(theta)),0.015f);
        float sigmaUV = min(0.45f/(facing*float(desktop.get_height())),0.03f)
                      + soft*0.030f*p*(0.25f+0.75f*(1.0f-facing));
        float3 rolled = foldSample(desktop,pyramid,s,float2(uv.x,1.0f-arc),sigmaUV);
        float lambert = max(0.0f,0.548f*sin(theta)-0.836f*cos(theta));
        float gloss = pow(lambert,14.0f);
        rolled *= mix(1.0f,0.42f+0.58f*lambert,0.35f+0.65f*shad)+gloss*(0.08f+0.20f*shad);
        float onRoll = smoothstep(0.0f,feather,radius-abs(h-tangent))
                     * smoothstep(0.0f,feather*2.0f+0.5f*sigmaUV,1.0f-arc);
        color = mix(color,rolled,onRoll);
        return float4(min(color,float3(1.0f))*(1.0f-smoothstep(0.88f,1.0f,p)),1);
    }

    static float4 foldShutter(float2 uv, texture2d<float> desktop, texture2d<float> pyramid,
                              sampler s, constant MacDuoUniformsMSL& u, float p) {
        float persp = clamp(u.perspective,0.0f,1.0f);
        float soft = clamp(u.blur,0.0f,1.0f);
        float shad = clamp(u.shadow,0.0f,1.0f);
        float h = 1.0f-uv.y;
        float aspect = max(u.size.x,1.0f)/max(u.size.y,1.0f);
        const float panel = 0.25f;
        float sink = panel+0.12f*persp;
        float relief = shad*smoothstep(0.0f,0.10f,p);
        float feather = 0.0016f+0.004f*soft;
        float3 color = float3(0.0f);
        float covered = 0.0f;
        for (uint j=0;j<4;j++) {
            float drop = p*(panel*float(j)+sink);
            float row = h+drop;
            float low = panel*float(j);
            float inset = persp*0.022f*float(j)*p/aspect;
            float cover = smoothstep(0.0f,feather,low+panel-row)*smoothstep(0.0f,feather,row-low)
                        * smoothstep(0.0f,feather,uv.x-inset)*smoothstep(0.0f,feather,1.0f-inset-uv.x);
            cover *= 1.0f-covered;
            if (cover <= 0.0f) continue;
            float sigmaUV = soft*0.014f*float(j)*p;
            float3 slab = foldSample(desktop,pyramid,s,float2(uv.x,1.0f-row),sigmaUV);
            float rim = 1.0f+relief*0.35f*exp(-(low+panel-row)/(0.004f+0.008f*soft));
            float shade = 1.0f-relief*0.09f*float(j)*p;
            if (j > 0u) {
                float frontTop = panel*float(j)-p*(panel*float(j-1u)+sink);
                shade *= 1.0f-relief*0.55f*exp(-max(0.0f,h-frontTop)/(0.012f+0.03f*soft));
            }
            color += min(slab*rim*shade,float3(1.0f))*cover;
            covered += cover;
        }
        return float4(color*(1.0f-smoothstep(0.90f,1.0f,p)),1);
    }

    static float4 foldFlex(float2 uv, texture2d<float> desktop, texture2d<float> pyramid,
                           sampler s, constant MacDuoUniformsMSL& u, float p) {
        float persp = clamp(u.perspective,0.0f,1.0f);
        float soft = clamp(u.blur,0.0f,1.0f);
        float shad = clamp(u.shadow,0.0f,1.0f);
        float h = 1.0f-uv.y;
        float lateral = (uv.x-0.5f)*2.0f;
        float collapse = 1.0f-0.85f*smoothstep(0.72f,1.0f,p);
        float top = (1.0f-0.40f*p)*collapse*(1.0f-p*0.10f*lateral*lateral);
        float eta = h/max(top,1e-4f);
        float bend = p*(0.45f+1.15f*persp);
        float material = eta*(1.0f+bend*eta)/(1.0f+bend);
        float waist = 1.0f-p*(0.10f+0.15f*persp)*material*material;
        float across = lateral/max(waist,1e-3f);
        float arc = p*(0.32f+0.42f*persp);
        float sweep = sin(arc);
        float unwrap = arc > 1e-4f ? asin(clamp(across*sweep,-0.99999f,0.99999f))/arc : across;
        float2 src = float2(0.5f+0.5f*unwrap,1.0f-material);

        float lean = clamp((1.0f+bend)/(1.0f+2.0f*bend*eta),0.02f,1.0f);
        float toward = clamp(lean*cos(unwrap*arc),0.02f,1.0f);
        float sigmaUV = min(0.45f/(lean*float(desktop.get_height())),0.02f)
                      + soft*p*(0.012f+0.030f*(1.0f-toward)+0.014f*eta);
        float3 color = foldSample(desktop,pyramid,s,src,sigmaUV);
        color *= mix(1.0f,0.35f+0.65f*toward,0.30f+0.70f*shad);
        float sheenWidth = 0.10f+0.35f*arc;
        float sheen = exp(-pow((unwrap*arc+0.75f*arc)/sheenWidth,2.0f))*(0.35f+0.65f*eta);
        color += sheen*(0.05f+0.13f*shad)*p;
        color *= 1.0f-shad*0.30f*exp(-h/0.03f);

        float fade = 0.0022f+0.004f*soft+1.2f*sigmaUV;
        float mask = smoothstep(0.0f,fade,1.0f-abs(across))*smoothstep(0.0f,fade,top-h)
                   * smoothstep(0.0f,p*(0.012f+0.025f*soft)+0.5f*sigmaUV,h);
        return float4(min(color,float3(1.0f))*mask*(1.0f-smoothstep(0.90f,1.0f,p)),1);
    }

    static float4 foldIris(float2 uv, texture2d<float> desktop, texture2d<float> pyramid,
                           sampler s, constant MacDuoUniformsMSL& u, float p) {
        float persp = clamp(u.perspective,0.0f,1.0f);
        float soft = clamp(u.blur,0.0f,1.0f);
        float shad = clamp(u.shadow,0.0f,1.0f);
        float aspect = max(u.size.x,1.0f)/max(u.size.y,1.0f);
        float2 q = float2((uv.x-0.5f)*aspect,(1.0f-uv.y)-0.14f);
        float aperture = 1.32f*pow(1.0f-p,1.3f);
        float curve = 0.30f*persp;
        float twist = p*(0.16f+0.22f*persp);
        const uint blades = 8u;
        float pitch = 2.0f*M_PI_F/float(blades);
        float overhang = aperture*tan(M_PI_F/float(blades))+0.10f;

        float outside = -1e9f;
        uint owner = 0u, strongest = 0u;
        bool claimed = false;
        float ownerEdge = 0.0f;
        for (uint i=0;i<blades;i++) {
            float phi = float(i)*pitch+twist;
            float along = q.x*cos(phi)+q.y*sin(phi);
            float across = q.y*cos(phi)-q.x*sin(phi);
            float edge = along-aperture-curve*across*across;
            if (edge > outside) { outside = edge; strongest = i; }
            if (!claimed && edge >= 0.0f && across >= -overhang) {
                claimed = true; owner = i; ownerEdge = edge;
            }
        }
        if (!claimed) { owner = strongest; ownerEdge = max(outside,0.0f); }

        float inside = max(0.0f,-outside);
        float rimSigma = soft*0.030f*exp(-inside/(0.035f+0.05f*soft));
        float3 color = foldSample(desktop,pyramid,s,uv,rimSigma);
        color *= 1.0f-shad*0.55f*exp(-inside/(0.028f+0.055f*soft));

        float phiOwner = float(owner)*pitch+twist;
        float tone = 0.052f+0.040f*(0.5f+0.5f*cos(phiOwner+0.7f));
        float body = tone*(1.0f-0.35f*smoothstep(0.0f,0.5f,ownerEdge));
        float seam = 1.0f;
        if (owner > 0u) {
            float phiAbove = float(owner-1u)*pitch+twist;
            float alongAbove = q.x*cos(phiAbove)+q.y*sin(phiAbove);
            float acrossAbove = q.y*cos(phiAbove)-q.x*sin(phiAbove);
            float past = -(acrossAbove+overhang);
            if (alongAbove >= aperture && past > 0.0f) {
                seam = 1.0f-(0.25f+0.45f*shad)*exp(-past/(0.010f+0.03f*soft));
            }
        }
        float shine = 0.26f*exp(-ownerEdge/(0.0035f+0.012f*soft));
        float3 blade = (body*seam+shine)*(1.0f-smoothstep(0.88f,1.0f,p));
        float aa = 1.5f/max(u.size.y,1.0f)+soft*0.0035f;
        return float4(min(mix(color,blade,smoothstep(0.0f,aa,outside)),float3(1.0f)),1);
    }

    fragment float4 foldFragment(Varying v [[stage_in]],
        texture2d<float> desktop [[texture(0)]], texture2d<float> pyramid [[texture(1)]],
        constant MacDuoUniformsMSL& u [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
        float p = clamp(u.progress,0.0f,1.0f);
        if (p < 0.00001f) return float4(desktop.sample(s,v.uv).rgb,1);
        if (u.fadeOnly > 0.5f) return float4(desktop.sample(s,v.uv).rgb*(1-p),1);
        if (p >= 1.0f) return float4(0,0,0,1);
        if (u.effect >= 1u && u.effect <= 4u) {
            float4 result;
            if (u.effect == 1u) result = foldRoll(v.uv,desktop,pyramid,s,u,p);
            else if (u.effect == 2u) result = foldShutter(v.uv,desktop,pyramid,s,u,p);
            else if (u.effect == 3u) result = foldFlex(v.uv,desktop,pyramid,s,u,p);
            else result = foldIris(v.uv,desktop,pyramid,s,u,p);
            if (p < 0.04f) {
                result.rgb = mix(desktop.sample(s,v.uv).rgb,result.rgb,smoothstep(0.0f,0.04f,p));
            }
            return result;
        }

        float height = 1.0f-v.uv.y;
        float expansion = 1.0f+p*(0.12f+mix(0.30f,0.66f,clamp(u.perspective,0.0f,1.0f))*height);
        float2 uv = float2(0.5f+(v.uv.x-0.5f)/expansion,1.0f-height/expansion);

        float focus = pow(p,0.7f);
        float spread = 0.12f+0.88f*pow(height,1.15f);
        float sigmaUV = clamp(u.blur,0.0f,1.0f)*0.052f*focus*spread;
        float sigma = sigmaUV*float(desktop.get_height());
        float lod = 0.5f*log2(1.0f+sigma*sigma*2.4f);
        lod = min(lod,float(pyramid.get_num_mip_levels()-1));
        float3 color = pyramid.sample(s,uv,level(lod)).rgb;
        float softness = clamp(u.blur,0.0f,1.0f);
        float topWidth = p*(0.075f+0.15f*softness)+1.5f*sigmaUV;
        float sideWidth = (p*(0.055f+0.12f*softness)+1.5f*sigmaUV)*u.size.y/u.size.x;
        float bottomWidth = p*(0.012f+0.025f*softness)+0.5f*sigmaUV;
        float mask = smoothstep(0.0f,topWidth,v.uv.y)*smoothstep(0.0f,bottomWidth,height)
                   * smoothstep(0.0f,sideWidth,v.uv.x)*smoothstep(0.0f,sideWidth,1.0f-v.uv.x);
        float shade = 1.0f-clamp(u.shadow,0.0f,1.0f)*0.12f*p*p*height;
        float disappear = 1.0f-smoothstep(0.86f,1.0f,p);
        return float4(color*mask*shade*disappear,1);
    }
    
    """#
}
