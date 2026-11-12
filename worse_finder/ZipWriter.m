//
//  ZipWriter.m
//  worse_finder
//

#import "ZipWriter.h"

#include <zlib.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <sys/stat.h>

static const uint32_t kMax32 = 0xFFFFFFFFu;
static const uint16_t kMax16 = 0xFFFFu;
static const size_t kChunk = 256 * 1024;

static void put16(FILE *f, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    fwrite(b, 1, 2, f);
}

static void put32(FILE *f, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff),
                     (uint8_t)((v >> 16) & 0xff), (uint8_t)((v >> 24) & 0xff) };
    fwrite(b, 1, 4, f);
}

static void put64(FILE *f, uint64_t v) {
    put32(f, (uint32_t)(v & 0xFFFFFFFFu));
    put32(f, (uint32_t)(v >> 32));
}

static void dataPut16(NSMutableData *d, uint16_t v) {
    uint8_t b[2] = { (uint8_t)(v & 0xff), (uint8_t)(v >> 8) };
    [d appendBytes:b length:2];
}

static void dataPut32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v & 0xff), (uint8_t)((v >> 8) & 0xff),
                     (uint8_t)((v >> 16) & 0xff), (uint8_t)((v >> 24) & 0xff) };
    [d appendBytes:b length:4];
}

static void dataPut64(NSMutableData *d, uint64_t v) {
    dataPut32(d, (uint32_t)(v & 0xFFFFFFFFu));
    dataPut32(d, (uint32_t)(v >> 32));
}

static void dos_stamp(time_t when, uint16_t *dtime, uint16_t *ddate) {
    struct tm parts;
    localtime_r(&when, &parts);
    int year = parts.tm_year + 1900;
    if (year < 1980) {
        year = 1980;
        parts.tm_mon = 0; parts.tm_mday = 1;
        parts.tm_hour = 0; parts.tm_min = 0; parts.tm_sec = 0;
    }
    *dtime = (uint16_t)((parts.tm_hour << 11) | (parts.tm_min << 5) | (parts.tm_sec / 2));
    *ddate = (uint16_t)(((year - 1980) << 9) | ((parts.tm_mon + 1) << 5) | parts.tm_mday);
}

static BOOL extension_is_compressed(NSString *name) {
    static NSSet<NSString *> *stored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        stored = [NSSet setWithArray:@[@"jpg", @"jpeg", @"png", @"heic", @"heif", @"gif",
                                       @"webp", @"mp4", @"mov", @"m4v", @"mp3", @"m4a",
                                       @"aac", @"zip", @"gz", @"xz", @"bz2", @"7z",
                                       @"ipa", @"dmg", @"pdf", @"woff", @"woff2"]];
    });
    NSString *ext = name.pathExtension.lowercaseString;
    return ext.length > 0 && [stored containsObject:ext];
}

@implementation ZipWriter {
    FILE *_fp;
    uint64_t _offset;
    NSMutableData *_central;
    uint64_t _entries;
    uint64_t _skipped;
    uint64_t _bytes;
    NSString *_error;
    BOOL _closed;
}

+ (instancetype)writerAtPath:(NSString *)path {
    return [[self alloc] initWithPath:path];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;

    _fp = fopen(path.fileSystemRepresentation, "wb+");
    if (!_fp) {
        _error = [NSString stringWithFormat:@"cannot create %@: %s", path, strerror(errno)];
        return nil;
    }
    _central = [NSMutableData data];
    _offset = 0;
    return self;
}

- (void)dealloc {
    if (_fp) fclose(_fp);
}

- (NSString *)lastError { return _error; }
- (uint64_t)entriesWritten { return _entries; }
- (uint64_t)filesSkipped { return _skipped; }
- (uint64_t)bytesWritten { return _bytes; }

#pragma mark - central directory

- (void)appendCentralRecord:(const char *)name
                     length:(size_t)nameLen
                     method:(uint16_t)method
                      crc:(uint32_t)crc
                compressed:(uint64_t)csize
              uncompressed:(uint64_t)usize
                    offset:(uint64_t)headerOffset
                       time:(uint16_t)dtime
                       date:(uint16_t)ddate
                        dir:(BOOL)isDir {
    BOOL bigSize = usize >= kMax32;
    BOOL bigComp = csize >= kMax32;
    BOOL bigOff = headerOffset >= kMax32;
    int fields = (bigSize ? 1 : 0) + (bigComp ? 1 : 0) + (bigOff ? 1 : 0);
    uint16_t extraLen = fields > 0 ? (uint16_t)(4 + fields * 8) : 0;

    dataPut32(_central, 0x02014b50);
    dataPut16(_central, 45);                       // version made by (4.5, MS-DOS host)
    dataPut16(_central, fields > 0 ? 45 : 20);     // version needed
    dataPut16(_central, 0x0800);                   // UTF-8 names
    dataPut16(_central, method);
    dataPut16(_central, dtime);
    dataPut16(_central, ddate);
    dataPut32(_central, crc);
    dataPut32(_central, bigComp ? kMax32 : (uint32_t)csize);
    dataPut32(_central, bigSize ? kMax32 : (uint32_t)usize);
    dataPut16(_central, (uint16_t)nameLen);
    dataPut16(_central, extraLen);
    dataPut16(_central, 0);                        // comment
    dataPut16(_central, 0);                        // disk start
    dataPut16(_central, 0);                        // internal attributes
    dataPut32(_central, isDir ? 0x41ED0010 : 0x81A40000);
    dataPut32(_central, bigOff ? kMax32 : (uint32_t)headerOffset);
    [_central appendBytes:name length:nameLen];

    if (extraLen > 0) {
        dataPut16(_central, 0x0001);
        dataPut16(_central, (uint16_t)(extraLen - 4));
        if (bigSize) dataPut64(_central, usize);
        if (bigComp) dataPut64(_central, csize);
        if (bigOff) dataPut64(_central, headerOffset);
    }
}

#pragma mark - entries

- (BOOL)addDirectory:(NSString *)entry {
    if (_closed) return NO;
    NSString *name = entry;
    if (![name hasSuffix:@"/"]) name = [name stringByAppendingString:@"/"];

    const char *cname = name.UTF8String;
    size_t nameLen = strlen(cname);
    uint64_t headerOffset = _offset;
    uint16_t dtime, ddate;
    dos_stamp(time(NULL), &dtime, &ddate);

    put32(_fp, 0x04034b50);
    put16(_fp, 20);
    put16(_fp, 0x0800);
    put16(_fp, 0);
    put16(_fp, dtime);
    put16(_fp, ddate);
    put32(_fp, 0);
    put32(_fp, 0);
    put32(_fp, 0);
    put16(_fp, (uint16_t)nameLen);
    put16(_fp, 0);
    fwrite(cname, 1, nameLen, _fp);

    _offset += 30 + nameLen;
    [self appendCentralRecord:cname length:nameLen method:0 crc:0 compressed:0
                 uncompressed:0 offset:headerOffset time:dtime date:ddate dir:YES];
    _entries++;
    return YES;
}

- (BOOL)addFile:(NSString *)source entry:(NSString *)entry {
    if (_closed) return NO;

    struct stat st;
    if (lstat(source.fileSystemRepresentation, &st) != 0) {
        _skipped++;
        return NO;
    }
    if (S_ISLNK(st.st_mode) || !S_ISREG(st.st_mode)) {
        _skipped++;
        return NO;
    }

    FILE *in = fopen(source.fileSystemRepresentation, "rb");
    if (!in) {
        _skipped++;
        return NO;
    }

    const char *cname = entry.UTF8String;
    size_t nameLen = strlen(cname);
    uint64_t usize = (uint64_t)st.st_size;
    BOOL store = extension_is_compressed(entry);
    uint16_t method = store ? 0 : 8;
    // Leave headroom so a slightly larger compressed size still fits 32 bits.
    BOOL bigLocal = usize >= (uint64_t)kMax32 - 4096;
    uint16_t extraLen = bigLocal ? 20 : 0;
    uint16_t dtime, ddate;
    dos_stamp(st.st_mtime, &dtime, &ddate);

    uint64_t headerOffset = _offset;
    put32(_fp, 0x04034b50);
    put16(_fp, bigLocal ? 45 : 20);
    put16(_fp, 0x0800);
    put16(_fp, method);
    put16(_fp, dtime);
    put16(_fp, ddate);
    put32(_fp, 0);
    put32(_fp, bigLocal ? kMax32 : 0);
    put32(_fp, bigLocal ? kMax32 : 0);
    put16(_fp, (uint16_t)nameLen);
    put16(_fp, extraLen);
    fwrite(cname, 1, nameLen, _fp);
    if (bigLocal) {
        put16(_fp, 0x0001);
        put16(_fp, 16);
        put64(_fp, usize);
        put64(_fp, 0);   // compressed size, patched below
    }

    _offset += 30 + nameLen + extraLen;
    uint64_t dataStart = _offset;

    uint8_t *inBuf = malloc(kChunk);
    uint8_t *outBuf = malloc(kChunk);
    uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
    uint64_t csize = 0;
    uint64_t readTotal = 0;
    BOOL ok = YES;

    if (store) {
        size_t n;
        while ((n = fread(inBuf, 1, kChunk, in)) > 0) {
            crc = (uint32_t)crc32(crc, inBuf, (uInt)n);
            if (fwrite(inBuf, 1, n, _fp) != n) { ok = NO; break; }
            csize += n;
            readTotal += n;
        }
    } else {
        z_stream zs;
        memset(&zs, 0, sizeof(zs));
        if (deflateInit2(&zs, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
                         Z_DEFAULT_STRATEGY) != Z_OK) {
            ok = NO;
        } else {
            size_t n;
            int rc = Z_OK;
            while (ok && (n = fread(inBuf, 1, kChunk, in)) > 0) {
                crc = (uint32_t)crc32(crc, inBuf, (uInt)n);
                readTotal += n;
                zs.next_in = inBuf;
                zs.avail_in = (uInt)n;
                while (zs.avail_in > 0) {
                    zs.next_out = outBuf;
                    zs.avail_out = (uInt)kChunk;
                    if (deflate(&zs, Z_NO_FLUSH) == Z_STREAM_ERROR) { ok = NO; break; }
                    size_t have = kChunk - zs.avail_out;
                    if (have && fwrite(outBuf, 1, have, _fp) != have) { ok = NO; break; }
                    csize += have;
                }
            }
            while (ok) {
                zs.next_out = outBuf;
                zs.avail_out = (uInt)kChunk;
                rc = deflate(&zs, Z_FINISH);
                size_t have = kChunk - zs.avail_out;
                if (have && fwrite(outBuf, 1, have, _fp) != have) { ok = NO; break; }
                csize += have;
                if (rc == Z_STREAM_END) break;
                if (rc != Z_OK) { ok = NO; break; }
            }
            deflateEnd(&zs);
        }
    }

    free(inBuf);
    free(outBuf);
    fclose(in);

    if (!ok) {
        _error = [NSString stringWithFormat:@"write failed for %@: %s", entry, strerror(errno)];
        _skipped++;
        return NO;
    }

    uint64_t dataEnd = dataStart + csize;

    // Patch the local header now that sizes and CRC are known.
    fseeko(_fp, (off_t)(headerOffset + 14), SEEK_SET);
    put32(_fp, crc);
    if (bigLocal) {
        fseeko(_fp, (off_t)(headerOffset + 30 + nameLen + 4 + 8), SEEK_SET);
        put64(_fp, csize);
    } else {
        put32(_fp, (uint32_t)csize);
        put32(_fp, (uint32_t)readTotal);
    }
    fseeko(_fp, (off_t)dataEnd, SEEK_SET);
    _offset = dataEnd;

    // A file that changed while it was read must be recorded at the size that
    // actually went into the archive, or the central directory disagrees with
    // the local header.
    [self appendCentralRecord:cname length:nameLen method:method crc:crc compressed:csize
                 uncompressed:readTotal offset:headerOffset time:dtime date:ddate dir:NO];

    _entries++;
    _bytes += readTotal;
    return YES;
}

- (BOOL)close {
    if (_closed) return NO;
    _closed = YES;
    if (!_fp) return NO;

    uint64_t cdOffset = _offset;
    if (_central.length) fwrite(_central.bytes, 1, _central.length, _fp);
    _offset += _central.length;
    uint64_t cdSize = _central.length;

    BOOL needZip64 = _entries >= kMax16 || cdOffset >= kMax32 || cdSize >= kMax32;

    if (needZip64) {
        uint64_t zip64Offset = _offset;
        put32(_fp, 0x06064b50);
        put64(_fp, 44);
        put16(_fp, 45);
        put16(_fp, 45);
        put32(_fp, 0);
        put32(_fp, 0);
        put64(_fp, _entries);
        put64(_fp, _entries);
        put64(_fp, cdSize);
        put64(_fp, cdOffset);
        put32(_fp, 0x07064b50);
        put32(_fp, 0);
        put64(_fp, zip64Offset);
        put32(_fp, 1);
        _offset += 56 + 20;
    }

    put32(_fp, 0x06054b50);
    put16(_fp, 0);
    put16(_fp, 0);
    put16(_fp, needZip64 ? kMax16 : (uint16_t)_entries);
    put16(_fp, needZip64 ? kMax16 : (uint16_t)_entries);
    put32(_fp, needZip64 ? kMax32 : (uint32_t)cdSize);
    put32(_fp, needZip64 ? kMax32 : (uint32_t)cdOffset);
    put16(_fp, 0);

    fflush(_fp);
    BOOL ok = (fclose(_fp) == 0);
    _fp = NULL;
    return ok;
}

@end
