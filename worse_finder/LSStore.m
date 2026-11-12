//
//  LSStore.m
//  worse_finder
//
//  lsd keeps its database (CSStore2, magic "bdsl") in a daemon container we can
//  read. Bundle records are preceded by [u32 id][u32 recordSize]; the fields we
//  need are string references (id << 2). Strings live as
//  [u32 id][u32 length][UTF-8][padding].
//

#import "LSStore.h"

#include <string.h>
#include <stdlib.h>
#include <sys/stat.h>

static const uint32_t kMaxStringID = 0x01000000u;
static const size_t kMaxStoreBytes = 64u * 1024u * 1024u;
static const size_t kMinStoreBytes = 0x1000;

typedef struct {
    const char *label;
    uint32_t recordSize;
    uint32_t bundleID;
    uint32_t name;
    uint32_t displayName;
    uint32_t container;
} LSLayout;

// 27.2 first: it is what the target device runs. Older layouts stay as a
// fallback so the app still names things after an OS update.
static const LSLayout kLayouts[] = {
    { "27.2", 0x25c, 0x0c, 0x70, 0x78, 0x6c },
    { "27.0", 0x250, 0x0c, 0x6c, 0x74, 0x68 },
    { "26",   0x23c, 0x0c, 0x68, 0x70, 0x64 },
};
static const size_t kLayoutCount = sizeof(kLayouts) / sizeof(kLayouts[0]);

static uint32_t rd32(const uint8_t *p) {
    uint32_t value;
    memcpy(&value, p, 4);
    return value;
}

static NSString *cs_string(const uint8_t *base, size_t size, size_t offset) {
    if (offset > size || size - offset < 8) return nil;
    uint32_t length = rd32(base + offset + 4);
    if (length == 0 || length >= 0x800 || length >= size - offset - 8) return nil;
    if ((length % 4) && base[offset + 8 + length] != 0) return nil;
    if (memchr(base + offset + 8, 0, length)) return nil;
    return [[NSString alloc] initWithBytes:base + offset + 8
                                    length:length
                                  encoding:NSUTF8StringEncoding];
}

static BOOL looks_like_bundle_id(NSString *value) {
    if (value.length < 3 || value.length > 200) return NO;
    if (![value containsString:@"."]) return NO;
    NSCharacterSet *bad = [[NSCharacterSet characterSetWithCharactersInString:
                            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"]
                           invertedSet];
    return [value rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static NSString *normalize_container(NSString *path) {
    if (!path.length) return nil;
    if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if ([path hasPrefix:@"/var/"]) path = [@"/private" stringByAppendingString:path];
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefixes = @[@"/private/var/mobile/Containers/Data/Application/",
                     @"/private/var/mobile/Containers/Data/PluginKitPlugin/"];
    });
    for (NSString *prefix in prefixes) {
        if (![path hasPrefix:prefix]) continue;
        NSString *uuid = [path substringFromIndex:prefix.length];
        if (uuid.length == 36 && [[NSUUID alloc] initWithUUIDString:uuid]) return path;
    }
    return nil;
}

BOOL wq_ls_store_candidate(NSString *path) {
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    if (!S_ISREG(st.st_mode)) return NO;
    if (st.st_size < (off_t)kMinStoreBytes || st.st_size > (off_t)kMaxStoreBytes) return NO;

    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return NO;
    char magic[4] = {0};
    ssize_t got = read(fd, magic, 4);
    close(fd);
    return got == 4 && memcmp(magic, "bdsl", 4) == 0;
}

static NSDictionary *parse_with_layout(const uint8_t *base, size_t size, const LSLayout *layout) {
    size_t recordCount = 0;
    for (size_t offset = 0; offset + 8 + layout->recordSize <= size; offset += 4) {
        if (rd32(base + offset + 4) == layout->recordSize) recordCount++;
    }
    if (recordCount == 0) return nil;

    // Bitmap of string ids the records reference.
    size_t bitmapSize = kMaxStringID / 8;
    uint8_t *needed = calloc(bitmapSize, 1);
    if (!needed) return nil;

    NSMutableData *records = [NSMutableData dataWithCapacity:recordCount * 4 * sizeof(uint32_t)];
    for (size_t offset = 0; offset + 8 + layout->recordSize <= size; offset += 4) {
        if (rd32(base + offset + 4) != layout->recordSize) continue;
        const uint8_t *body = base + offset + 8;
        uint32_t fields[4] = { rd32(body + layout->bundleID), rd32(body + layout->name),
                               rd32(body + layout->displayName), rd32(body + layout->container) };
        if (!fields[0] || (fields[0] & 3) || (fields[0] >> 2) >= kMaxStringID) continue;
        [records appendBytes:fields length:sizeof(fields)];
        for (int index = 0; index < 4; index++) {
            uint32_t ref = fields[index];
            if (ref && !(ref & 3) && (ref >> 2) < kMaxStringID) {
                uint32_t id = ref >> 2;
                needed[id / 8] |= (uint8_t)(1 << (id % 8));
            }
        }
    }

    NSMutableDictionary<NSNumber *, NSString *> *strings = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSNumber *, NSString *> *paths = [NSMutableDictionary dictionary];
    for (size_t offset = 0; offset + 8 <= size; offset += 4) {
        uint32_t id = rd32(base + offset);
        if (!id || id >= kMaxStringID) continue;
        if (!(needed[id / 8] & (1 << (id % 8)))) continue;
        NSString *value = cs_string(base, size, offset);
        if (!value) continue;
        if ([value hasPrefix:@"/"]) paths[@(id)] = value;
        else strings[@(id)] = value;
    }
    free(needed);

    NSMutableDictionary<NSString *, NSString *> *containers = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    const uint32_t *fields = records.bytes;
    for (NSUInteger index = 0; index + 4 <= records.length / sizeof(uint32_t); index += 4) {
        NSString *bundleID = strings[@(fields[index] >> 2)];
        if (!looks_like_bundle_id(bundleID)) continue;

        NSString *display = strings[@(fields[index + 2] >> 2)];
        NSString *bundleName = strings[@(fields[index + 1] >> 2)];
        NSString *name = display.length ? display : bundleName;
        if (name.length && !names[bundleID]) names[bundleID] = name;

        if (!fields[index + 3]) continue;
        NSString *raw = paths[@(fields[index + 3] >> 2)] ?: strings[@(fields[index + 3] >> 2)];
        NSString *container = normalize_container(raw);
        if (container && !containers[container]) containers[container] = bundleID;
    }

    if (containers.count == 0) return nil;
    return @{ @"containers": containers, @"names": names,
              @"layout": [NSString stringWithUTF8String:layout->label] };
}

NSDictionary<NSString *, id> *wq_ls_parse_store(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:nil];
    if (data.length < kMinStoreBytes || data.length > kMaxStoreBytes) return nil;
    const uint8_t *base = data.bytes;
    size_t size = data.length;
    if (memcmp(base, "bdsl", 4) != 0) return nil;

    NSDictionary *best = nil;
    for (size_t index = 0; index < kLayoutCount; index++) {
        NSDictionary *result = parse_with_layout(base, size, &kLayouts[index]);
        if (!result) continue;
        NSUInteger count = [result[@"containers"] count];
        if (!best || count > [best[@"containers"] count]) best = result;
    }
    return best;
}
