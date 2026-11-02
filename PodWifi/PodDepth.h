//
//  PodDepth.h
//  轻量双目深度：SAD 块匹配 + 左右一致性校验（不依赖 OpenCV）
//
//  为什么不用 OpenCV 的 SGBM+WLS：iOS 要额外链 ~90MB 的 opencv2.framework，
//  而本项目只需要"正前方有没有障碍、大概多远"，一块 5x5 SAD 足够，且零外部依赖、
//  参数完全可控（能和标定常数逐项对上）。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PodDepthResult : NSObject
/// 视差图尺寸（是输入的一半，SAD 在半分辨率上算，速度快 4 倍）
@property (nonatomic, readonly) int width;
@property (nonatomic, readonly) int height;
/// 内部缓冲：int16，单位=半分辨率像素；-1 表示无效
@property (nonatomic, readonly) NSData *buffer;

/// 取某点视差（越界返回 -1）
- (int16_t)dispAtX:(int)x y:(int)y;

/// 指定矩形区域内有效视差的中位数（半分辨率坐标）；无有效值返回 -1
- (float)medianInX0:(int)x0 y0:(int)y0 x1:(int)x1 y1:(int)y1;

/// v0.6.0：带抽样步长的中位数（YOLO 框内取距离用；stride=2 省 4 倍排序时间，误差 <0.5%）
- (float)medianInX0:(int)x0 y0:(int)y0 x1:(int)x1 y1:(int)y1 stride:(int)stride;

/// 有效像素占比（0..1），用于判断这一帧深度是否可信（弱纹理/过曝会很低）
- (float)validRatio;
@end

@interface PodDepth : NSObject

/// v0.5.0 的固定参数版本（保留：调用方不必改，内部转发到下面那个全参数版本）
/// left/right 为同一尺寸的 8bit 灰度图。maxDisparity 以**半分辨率**计（建议 48）。
+ (nullable PodDepthResult *)computeLeft:(const uint8_t *)left
                                   right:(const uint8_t *)right
                                   width:(int)width
                                  height:(int)height
                            maxDisparity:(int)maxDisparity;

/// v0.6.0：全部 SAD 参数可调（参数含义见 Swift 侧 DepthParams 注释）
/// - windowRadius:     SAD 窗口半径，2=5x5、3=7x7
/// - uniquenessPct:    次优/最优 代价比阈值，默认 1.08
/// - uniquenessMargin: 额外绝对裕度，默认 12
/// - lrcTol:           左右一致性容差（半分辨率像素），默认 1
/// - textureGate:      5x5 窗口灰度 max-min 门限，0 = 关闭
+ (nullable PodDepthResult *)computeLeft:(const uint8_t *)left
                                   right:(const uint8_t *)right
                                   width:(int)width
                                  height:(int)height
                            maxDisparity:(int)maxDisparity
                            windowRadius:(int)windowRadius
                          uniquenessPct:(float)uniquenessPct
                       uniquenessMargin:(int)uniquenessMargin
                                  lrcTol:(int)lrcTol
                             textureGate:(int)textureGate;

@end

NS_ASSUME_NONNULL_END
