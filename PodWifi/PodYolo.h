//
//  PodYolo.h
//  YOLOv26n（ncnn）检测器，前后处理逐项对齐安卓 cpp/yolov26ncnn.cpp
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PodDet : NSObject
@property (nonatomic, assign) float cx;     // 归一化中心 x
@property (nonatomic, assign) float cy;     // 归一化中心 y
@property (nonatomic, assign) float w;      // 归一化宽
@property (nonatomic, assign) float h;      // 归一化高
@property (nonatomic, assign) int   label;  // 类别索引（0..9）
@property (nonatomic, assign) float prob;
@end

@interface PodYolo : NSObject

/// 加载 .param / .bin（用文件路径，ncnn 自己做 mmap）
- (BOOL)loadParamPath:(NSString *)paramPath modelPath:(NSString *)binPath;
@property (nonatomic, readonly) BOOL isLoaded;

/// 输入 BGRA8 像素（CVPixelBuffer 直接给），返回 PodDet 数组（已做 NMS）
- (NSArray<PodDet *> *)detectBGRA:(const uint8_t *)bgra
                            width:(int)width
                           height:(int)height;

@end

NS_ASSUME_NONNULL_END
