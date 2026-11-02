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

/// 有效像素占比（0..1），用于判断这一帧深度是否可信（弱纹理/过曝会很低）
- (float)validRatio;
@end

@interface PodDepth : NSObject

/// left/right 为同一尺寸的 8bit 灰度图。maxDisparity 以**半分辨率**计（建议 48）。
+ (nullable PodDepthResult *)computeLeft:(const uint8_t *)left
                                   right:(const uint8_t *)right
                                   width:(int)width
                                  height:(int)height
                            maxDisparity:(int)maxDisparity;

@end

NS_ASSUME_NONNULL_END
