//
//  PodDepth.mm
//  SAD 块匹配实现（半分辨率 + 左右一致性校验 + 唯一性裕度）
//

#import "PodDepth.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <vector>

// 只读属性对外，内部用类扩展开放读写
@interface PodDepthResult ()
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, strong) NSData *buffer;
@end

@implementation PodDepthResult

- (int16_t)dispAtX:(int)x y:(int)y {
    if (x < 0 || y < 0 || x >= _width || y >= _height) { return -1; }
    const int16_t *p = (const int16_t *)_buffer.bytes;
    return p[y * _width + x];
}

- (float)medianInX0:(int)x0 y0:(int)y0 x1:(int)x1 y1:(int)y1 {
    std::vector<int16_t> v;
    const int16_t *p = (const int16_t *)_buffer.bytes;
    int ax = std::max(0, x0), ay = std::max(0, y0);
    int bx = std::min(_width - 1, x1), by = std::min(_height - 1, y1);
    for (int y = ay; y <= by; y++) {
        for (int x = ax; x <= bx; x++) {
            int16_t d = p[y * _width + x];
            if (d >= 0) { v.push_back(d); }
        }
    }
    if (v.empty()) { return -1.f; }
    std::sort(v.begin(), v.end());
    return (float)v[v.size() / 2];
}

- (float)validRatio {
    const int16_t *p = (const int16_t *)_buffer.bytes;
    int n = _width * _height;
    if (n <= 0) { return 0.f; }
    int ok = 0;
    for (int i = 0; i < n; i++) {
        if (p[i] >= 0) { ok++; }
    }
    return (float)ok / (float)n;
}

@end

@implementation PodDepth

+ (nullable PodDepthResult *)computeLeft:(const uint8_t *)left
                                   right:(const uint8_t *)right
                                   width:(int)width
                                  height:(int)height
                            maxDisparity:(int)maxDisparity {
    if (left == nullptr || right == nullptr || width < 32 || height < 32) { return nil; }

    const int hw = width / 2;
    const int hh = height / 2;
    if (hw < 16 || hh < 16) { return nil; }

    // 1) 2x2 均值降采样 → 抗噪，同时把计算量降到 1/4
    std::vector<uint8_t> L(hw * hh), R(hw * hh);
    for (int y = 0; y < hh; y++) {
        for (int x = 0; x < hw; x++) {
            int sx = x * 2, sy = y * 2;
            int i0 = sy * width + sx;
            int i1 = i0 + 1;
            int i2 = i0 + width;
            int i3 = i2 + 1;
            L[y * hw + x] = (uint8_t)((left[i0] + left[i1] + left[i2] + left[i3]) >> 2);
            R[y * hw + x] = (uint8_t)((right[i0] + right[i1] + right[i2] + right[i3]) >> 2);
        }
    }

    const int maxD = std::max(4, std::min(maxDisparity, hw - 8));
    const int R_WIN = 2;              // 5x5 窗口
    const int margin = 12;            // 前向一致性裕度（SAD 差值需小于 best*1.08 + margin）

    std::vector<int16_t> disp(hw * hh, -1);

    // 2) 左→右 SAD
    for (int y = R_WIN; y < hh - R_WIN; y++) {
        for (int x = R_WIN; x < hw - R_WIN; x++) {
            uint32_t bestCost = 0xFFFFFFFFu;
            int best = -1;
            uint32_t secondCost = 0xFFFFFFFFu;
            for (int d = 0; d <= maxD; d++) {
                int rx = x - d;
                if (rx < R_WIN) { break; }
                uint32_t cost = 0;
                for (int dy = -R_WIN; dy <= R_WIN; dy++) {
                    const uint8_t *lp = &L[(y + dy) * hw + (x - R_WIN)];
                    const uint8_t *rp = &R[(y + dy) * hw + (rx - R_WIN)];
                    for (int dx = 0; dx <= 2 * R_WIN; dx++) {
                        int diff = (int)lp[dx] - (int)rp[dx];
                        cost += (uint32_t)(diff < 0 ? -diff : diff);
                    }
                }
                if (cost < bestCost) {
                    secondCost = bestCost;
                    bestCost = cost;
                    best = d;
                } else if (cost < secondCost) {
                    secondCost = cost;
                }
            }
            if (best < 0) { continue; }
            // 唯一性：最优明显好于次优，否则认为纹理不足/歧义
            if ((float)secondCost < (float)bestCost * 1.08f + (float)margin) { continue; }
            disp[y * hw + x] = (int16_t)best;
        }
    }

    // 3) 左右一致性校验：把左视差投到右图，再在右图找最优，差<=1 才采纳
    for (int y = R_WIN; y < hh - R_WIN; y++) {
        for (int x = R_WIN; x < hw - R_WIN; x++) {
            int16_t d = disp[y * hw + x];
            if (d < 0) { continue; }
            int rx = x - d;
            if (rx < R_WIN || rx >= hw - R_WIN) { disp[y * hw + x] = -1; continue; }

            uint32_t bestCost = 0xFFFFFFFFu;
            int best = -1;
            for (int dd = 0; dd <= maxD; dd++) {
                int lx = rx + dd;
                if (lx >= hw - R_WIN) { break; }
                uint32_t cost = 0;
                for (int dy = -R_WIN; dy <= R_WIN; dy++) {
                    const uint8_t *rp = &R[(y + dy) * hw + (rx - R_WIN)];
                    const uint8_t *lp = &L[(y + dy) * hw + (lx - R_WIN)];
                    for (int dx = 0; dx <= 2 * R_WIN; dx++) {
                        int diff = (int)rp[dx] - (int)lp[dx];
                        cost += (uint32_t)(diff < 0 ? -diff : diff);
                    }
                }
                if (cost < bestCost) { bestCost = cost; best = dd; }
            }
            if (best < 0 || std::abs(best - (int)d) > 1) { disp[y * hw + x] = -1; }
        }
    }

    PodDepthResult *res = [[PodDepthResult alloc] init];
    res.width = hw;
    res.height = hh;
    res.buffer = [NSData dataWithBytes:disp.data() length:disp.size() * sizeof(int16_t)];
    return res;
}

@end
