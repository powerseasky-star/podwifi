//
//  PodWhisper.mm
//  whisper.cpp 薄封装实现（纯 C 调用，见头文件里的理由）
//

#import "PodWhisper.h"

// 头文件可能有两种布局：framework 形式 <whisper/whisper.h> 或平铺 whisper.h
#if __has_include(<whisper/whisper.h>)
#import <whisper/whisper.h>
#else
#import "whisper.h"
#endif

@implementation PodWhisper {
    struct whisper_context *_ctx;
}

- (instancetype)init {
    self = [super init];
    if (self) { _ctx = NULL; }
    return self;
}

- (BOOL)isLoaded {
    return _ctx != NULL;
}

- (BOOL)loadModelAtPath:(NSString *)path {
    if (path.length == 0) { return NO; }
    if (_ctx != NULL) {
        whisper_free(_ctx);
        _ctx = NULL;
    }
    // 只用默认参数：不同版本的 whisper_context_params 字段会增减，
    // 逐字段赋值会在换版本时编译失败（本项目无法本地预编译，宁可保守）。
    struct whisper_context_params cparams = whisper_context_default_params();
    _ctx = whisper_init_from_file_with_params(path.UTF8String, cparams);
    return _ctx != NULL;
}

- (NSString *)transcribeSamples:(const float *)samples count:(int)count {
    if (_ctx == NULL || samples == NULL || count <= 0) { return @""; }

    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.n_threads        = 4;
    p.translate        = false;
    p.no_context       = true;   // 每句独立，避免上一句污染
    p.single_segment   = true;   // 一句命令只要一段结果
    p.print_special    = false;
    p.print_progress   = false;
    p.print_realtime   = false;
    p.print_timestamps = false;

    // language 是 const char*，必须保证生命周期覆盖 whisper_full 调用
    const char *lang = "zh";
    p.language = lang;

    int rc = whisper_full(_ctx, p, samples, count);
    if (rc != 0) { return @""; }

    int n = whisper_full_n_segments(_ctx);
    NSMutableString *out = [NSMutableString string];
    for (int i = 0; i < n; i++) {
        const char *t = whisper_full_get_segment_text(_ctx, i);
        if (t == NULL) { continue; }
        NSString *s = [NSString stringWithUTF8String:t];
        if (s.length > 0) { [out appendString:s]; }
    }
    return [out copy];
}

- (void)unload {
    if (_ctx != NULL) {
        whisper_free(_ctx);
        _ctx = NULL;
    }
}

- (void)dealloc {
    if (_ctx != NULL) {
        whisper_free(_ctx);
        _ctx = NULL;
    }
}

@end
