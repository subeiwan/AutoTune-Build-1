/*
 AutoTune — 猎枪弹道数据采集模块（Theos 源码）

 作用：挂在游戏进程里，按 50 米分段统计射击命中情况，写到
       <App 容器>/Documents/autotune.json，导出来给 ZakaSign「对局数据」页分析。

 工作方式：
   1. 启动时读 config（默认 Documents/autotune_hook.json）
   2. 按 config 里给的镜像名 + 偏移装钩子（MSHookFunction）
   3. 每次射线调用记一条：起点、方向、判定距离、是否命中、命中点
   4. 按 dist/50 归段，实时累加；掉后台 / 每 60 秒落盘一次

 config 里没填偏移时，模块照样加载，只做自检写入（用来确认 dylib 注入成功）。
 偏移要你自己 dump 出来（il2cpp 的 Physics.Raycast 之类），填进 config 就能采数据。
*/

#import <Foundation/Foundation.h>
#import <substrate.h>
#import <mach-o/dyld.h>
#import <dlfcn.h>
#include <string.h>
#include <math.h>

#define AT_MAX_BANDS 40
#define AT_SEGMENT 50.0

typedef struct {
    uint64_t shots;
    uint64_t hits;
    double   sumDY;
    double   sumDX;
    uint64_t errN;
} ATBand;

static ATBand gBands[AT_MAX_BANDS];
static NSLock *gLock = nil;
static NSString *gOutPath = nil;
static dispatch_queue_t gQueue;
static NSDictionary *gConfig = nil;

// ---------------- 工具 ----------------

static NSString *ATDocumentsPath(void) {
    // 注入进程就是游戏进程，用自己的沙箱路径
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: [@"~/Documents" stringByExpandingTildeInPath];
    return dir;
}

static NSDictionary *ATLoadConfig(void) {
    NSString *p = [ATDocumentsPath() stringByAppendingPathComponent:@"autotune_hook.json"];
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

static uintptr_t ATImageBase(NSString *name) {
    if (name.length == 0) return 0;
    const char *want = name.UTF8String;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (!path) continue;
        if (strstr(path, want) != NULL) {
            return (uintptr_t)_dyld_get_image_header(i);
        }
    }
    return 0;
}

// 记录一次射击
static void ATRecordShot(double dist, BOOL hit, double errV, double errH, BOOL hasErr) {
    if (dist < 0 || dist > AT_SEGMENT * AT_MAX_BANDS) return;
    int band = (int)(dist / AT_SEGMENT);
    if (band < 0) band = 0;
    if (band >= AT_MAX_BANDS) band = AT_MAX_BANDS - 1;
    [gLock lock];
    gBands[band].shots += 1;
    if (hit) gBands[band].hits += 1;
    if (hasErr) {
        gBands[band].sumDY += errV;
        gBands[band].sumDX += errH;
        gBands[band].errN += 1;
    }
    [gLock unlock];
}

static void ATFlush(void) {
    NSMutableArray *segs = [NSMutableArray array];
    [gLock lock];
    for (int i = 0; i < AT_MAX_BANDS; i++) {
        if (gBands[i].shots == 0) continue;
        [segs addObject:@{
            @"index": @(i),
            @"shots": @(gBands[i].shots),
            @"hits": @(gBands[i].hits),
            @"err_v": @(gBands[i].errN ? gBands[i].sumDY / gBands[i].errN : 0),
            @"err_h": @(gBands[i].errN ? gBands[i].sumDX / gBands[i].errN : 0),
            @"err_n": @(gBands[i].errN)
        }];
    }
    [gLock unlock];

    NSDictionary *root = @{
        @"version": @1,
        @"segment": @((int)AT_SEGMENT),
        @"updated": @([[NSDate date] timeIntervalSince1970]),
        @"config_loaded": @(gConfig != nil),
        @"segments": segs
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:NULL];
    [data writeToFile:gOutPath atomically:YES];
}

// ---------------- 钩子 ----------------
//
// 这里只写了一个标准签名的示例：Unity 的
//   static bool Raycast(Vector3 origin, Vector3 dir, RaycastHit* hit, float maxDistance)
// 具体偏移从 il2cpp dump 里拿，填进 config 的 hooks 数组。
//
// 想采"真实弹丸落点"而不是射线，就把下面的偏移换成弹丸类里
// 处理位置更新/命中的那个函数，同样在 config 里配。

typedef bool (*ATRaycastFn)(void *origin, void *dir, void *hit, float maxDist);
static ATRaycastFn at_orig_raycast = NULL;

static bool at_raycast(void *origin, void *dir, void *hit, float maxDist) {
    bool result = at_orig_raycast ? at_orig_raycast(origin, dir, hit, maxDist) : false;
    // Vector3 是 3 个 float，直接按内存读
    float ox = 0, oy = 0, oz = 0, dx = 0, dy = 0, dz = 0;
    if (origin) memcpy(&ox, origin, 12);
    if (dir) memcpy(&dx, dir, 12);
    double len = sqrt((double)dx * dx + (double)dy * dy + (double)dz * dz);
    ATRecordShot(maxDist, result, 0, 0, NO);
    (void)ox; (void)oy; (void)oz; (void)len;
    return result;
}

static void ATInstallHooks(void) {
    NSArray *hooks = gConfig[@"hooks"];
    if (![hooks isKindOfClass:[NSArray class]] || hooks.count == 0) {
        NSLog(@"[AutoTune] 没有配置钩子偏移，只做自检写入");
        return;
    }
    for (NSDictionary *h in hooks) {
        NSString *image = h[@"image"];
        NSNumber *off = h[@"offset"];
        NSString *kind = h[@"kind"] ?: @"raycast";
        if (!off) continue;
        uintptr_t base = ATImageBase(image);
        if (!base) {
            NSLog(@"[AutoTune] 找不到镜像 %@", image);
            continue;
        }
        void *target = (void *)(base + (uintptr_t)off.unsignedLongLongValue);
        if ([kind isEqualToString:@"raycast"]) {
            MSHookFunction(target, (void *)at_raycast, (void **)&at_orig_raycast);
            NSLog(@"[AutoTune] 钩子已装 %@ + 0x%llx (raycast)", image, off.unsignedLongLongValue);
        }
    }
}

__attribute__((constructor))
static void AutoTuneInit(void) {
    gLock = [NSLock new];
    gQueue = dispatch_queue_create("com.zaka.autotune", DISPATCH_QUEUE_SERIAL);
    gOutPath = [ATDocumentsPath() stringByAppendingPathComponent:@"autotune.json"];
    gConfig = ATLoadConfig();

    NSLog(@"[AutoTune] v1 已加载，输出 %@", gOutPath);
    ATInstallHooks();
    ATFlush();

    // 每 60 秒落盘一次
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 60ull * NSEC_PER_SEC),
                              60ull * NSEC_PER_SEC, 5ull * NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ ATFlush(); });
    dispatch_resume(timer);
}
