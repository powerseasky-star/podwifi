//
//  PodWhisper.h
//  whisper.cpp 的薄 Objective-C 封装。
//
//  为什么不用 Swift 直接调 whisper 的 C API：whisper_full_params 是一大坨 C 结构体，
//  里面还有 C 枚举常量（WHISPER_SAMPLING_GREEDY），Swift 侧导入形态随 SDK 版本有差异，
//  而本项目只能在云端 macOS runner 上编译（本地无 Xcode），一旦写错就要盲改。
//  放在 ObjC++ 里就是纯 C，命名与头文件逐字一致，没有歧义。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PodWhisper : NSObject

/// 加载 ggml 模型（.bin）。返回 NO 表示失败（路径错/文件损坏/内存不够）。
- (BOOL)loadModelAtPath:(NSString *)path;

/// 是否已加载
@property (nonatomic, readonly) BOOL isLoaded;

/// 识别一段 16kHz 单声道 Float32 采样。返回识别文本（可能为空串）。
/// 注意：这是**同步阻塞**调用，必须在后台线程执行。
- (NSString *)transcribeSamples:(const float *)samples count:(int)count;

/// 释放模型
- (void)unload;

@end

NS_ASSUME_NONNULL_END
