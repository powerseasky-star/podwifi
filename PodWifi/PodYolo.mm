//
//  PodYolo.mm
//  逐项对齐安卓 cpp/yolov26ncnn.cpp：letterbox(114 灰边) → 0..1 归一化 →
//  自适应转置布局 → 自适应 sigmoid → 阈值 0.20 / NMS 0.50
//

#import "PodYolo.h"

#include <algorithm>
#include <cmath>
#include <vector>

#include "net.h"

@implementation PodDet
@end

@implementation PodYolo {
    ncnn::Net *_net;
}

- (instancetype)init {
    self = [super init];
    if (self) { _net = nullptr; }
    return self;
}

- (BOOL)isLoaded { return _net != nullptr; }

- (BOOL)loadParamPath:(NSString *)paramPath modelPath:(NSString *)binPath {
    if (paramPath.length == 0 || binPath.length == 0) { return NO; }
    if (_net) { delete _net; _net = nullptr; }
    _net = new ncnn::Net();
    // 与安卓一致：不开 vulkan（iOS 上 MoltenVK 依赖额外库，先用 CPU 求稳）
    _net->opt.use_vulkan_compute = false;
    _net->opt.num_threads = 4;
    _net->opt.use_fp16_packed = true;
    _net->opt.use_fp16_storage = true;
    _net->opt.use_fp16_arithmetic = true;

    int r1 = _net->load_param(paramPath.UTF8String);
    int r2 = _net->load_model(binPath.UTF8String);
    if (r1 != 0 || r2 != 0) {
        delete _net;
        _net = nullptr;
        return NO;
    }
    return YES;
}

static void nms(std::vector<PodDet *> &objs, float thresh) {
    std::sort(objs.begin(), objs.end(), [](PodDet *a, PodDet *b) {
        return a.prob > b.prob;
    });
    for (size_t i = 0; i < objs.size(); i++) {
        PodDet *a = objs[i];
        if (a.prob < 0) { continue; }
        float ax1 = a.cx - a.w * 0.5f, ay1 = a.cy - a.h * 0.5f;
        float ax2 = a.cx + a.w * 0.5f, ay2 = a.cy + a.h * 0.5f;
        for (size_t j = i + 1; j < objs.size(); j++) {
            PodDet *b = objs[j];
            if (b.prob < 0) { continue; }
            float bx1 = b.cx - b.w * 0.5f, by1 = b.cy - b.h * 0.5f;
            float bx2 = b.cx + b.w * 0.5f, by2 = b.cy + b.h * 0.5f;
            float ix = std::max(0.f, std::min(ax2, bx2) - std::max(ax1, bx1));
            float iy = std::max(0.f, std::min(ay2, by2) - std::max(ay1, by1));
            float inter = ix * iy;
            float uni = a.w * a.h + b.w * b.h - inter;
            float iou = uni > 0 ? inter / uni : 0.f;
            if (iou > thresh) { b.prob = -1.f; }
        }
    }
    objs.erase(std::remove_if(objs.begin(), objs.end(),
                              [](PodDet *o) { return o.prob < 0; }),
               objs.end());
}

- (NSArray<PodDet *> *)detectBGRA:(const uint8_t *)bgra
                            width:(int)width
                           height:(int)height {
    if (_net == nullptr || bgra == nullptr || width <= 0 || height <= 0) { return @[]; }

    const int target = 640;
    // 1) letterbox：等比缩放 + 114 灰边（与 ultralytics 一致）
    float scale = std::min((float)target / width, (float)target / height);
    int nw = (int)roundf(width * scale);
    int nh = (int)roundf(height * scale);
    int px = (target - nw) / 2;
    int py = (target - nh) / 2;

    ncnn::Mat in = ncnn::Mat::from_pixels_resize(bgra, ncnn::Mat::PIXEL_BGRA2RGB,
                                                 width, height, nw, nh);
    ncnn::Mat padded(target, target, 3);
    padded.fill(114.f);
    for (int c = 0; c < 3; c++) {
        const float *src = (const float *)in.channel(c).data;
        float *dst = (float *)padded.channel(c).data + py * target + px;
        for (int y = 0; y < nh; y++) {
            memcpy(dst + y * target, src + y * nw, nw * sizeof(float));
        }
    }
    const float mean[3] = {0.f, 0.f, 0.f};
    const float norm[3] = {1 / 255.f, 1 / 255.f, 1 / 255.f};
    padded.substract_mean_normalize(mean, norm);

    // 2) 前向（每帧新建 extractor：安卓实测复用会在某些后端冻结输出）
    ncnn::Extractor ex = _net->create_extractor();
    int rin = ex.input("in0", padded);
    if (rin != 0) { rin = ex.input(0, padded); }
    if (rin != 0) { return @[]; }

    ncnn::Mat out;
    int r = ex.extract("out0", out);
    if (r != 0) { r = ex.extract("output", out); }
    if (r != 0) { r = ex.extract(0, out); }
    if (r != 0) { return @[]; }

    // 3) 自适应布局与 sigmoid（实测 pnnx 导出为转置 8400x84）
    const bool transposed = (out.h <= 200 && out.w > out.h);
    const int num_class = (transposed ? out.h : out.w) - 4;
    const int num_anchors = transposed ? out.w : out.h;
    if (num_class < 1 || num_anchors < 1) { return @[]; }

    auto rawVal = [&](int ch, int a) -> float {
        return transposed ? out.row(ch)[a] : out.row(a)[ch];
    };

    float gmax = -1e9f;
    for (int k = 4; k < 4 + num_class; k++) {
        for (int a = 0; a < num_anchors; a++) {
            float v = rawVal(k, a);
            if (v > gmax) { gmax = v; }
        }
    }
    const bool needSigmoid = gmax > 2.0f;

    const float prob_threshold = 0.20f;
    const float nms_threshold = 0.50f;

    std::vector<PodDet *> props;
    for (int a = 0; a < num_anchors; a++) {
        int label = -1;
        float score = -1.f;
        for (int k = 0; k < num_class; k++) {
            float s = rawVal(4 + k, a);
            if (needSigmoid) { s = 1.f / (1.f + expf(-s)); }
            if (s > score) { score = s; label = k; }
        }
        if (score < prob_threshold || label < 0) { continue; }

        float bx = rawVal(0, a), by = rawVal(1, a);
        float bw = rawVal(2, a), bh = rawVal(3, a);
        float ox = bx - px, oy = by - py;
        if (ox < 0 || oy < 0) { continue; }

        PodDet *d = [[PodDet alloc] init];
        d.cx = std::min(1.f, std::max(0.f, (ox / scale) / (float)width));
        d.cy = std::min(1.f, std::max(0.f, (oy / scale) / (float)height));
        d.w = std::min(1.f, std::max(0.f, (bw / scale) / (float)width));
        d.h = std::min(1.f, std::max(0.f, (bh / scale) / (float)height));
        d.label = label;
        d.prob = score;
        props.push_back(d);
    }

    nms(props, nms_threshold > 1.f ? 1.f : nms_threshold);

    NSMutableArray<PodDet *> *outArr = [NSMutableArray arrayWithCapacity:props.size()];
    for (auto *p : props) { [outArr addObject:p]; }
    return outArr;
}

- (void)dealloc {
    if (_net) { delete _net; _net = nullptr; }
}

@end
