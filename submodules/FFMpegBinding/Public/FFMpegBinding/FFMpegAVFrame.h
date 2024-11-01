#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, FFMpegAVFrameColorRange) {
    FFMpegAVFrameColorRangeRestricted,
    FFMpegAVFrameColorRangeFull
};

typedef NS_ENUM(NSUInteger, FFMpegAVFramePixelFormat) {
    FFMpegAVFramePixelFormatYUV,
    FFMpegAVFramePixelFormatYUVA
};

@interface FFMpegAVFrame : NSObject

@property (nonatomic, readonly) int32_t width;
@property (nonatomic, readonly) int32_t height;
@property (nonatomic, readonly) uint8_t * _Nullable * _Nonnull data;
@property (nonatomic, readonly) int * _Nonnull lineSize;
@property (nonatomic, readonly) int64_t pts;
@property (nonatomic, readonly) int64_t duration;
@property (nonatomic, readonly) FFMpegAVFrameColorRange colorRange;
@property (nonatomic, readonly) FFMpegAVFramePixelFormat pixelFormat;
@property (nonatomic, readonly) int32_t sampleRate;
@property (nonatomic, readonly) int64_t bestEffortTimestamp;
@property (nonatomic, readonly) int64_t pktDts;
@property (nonatomic, readonly) int32_t nbSamples;
@property (nonatomic, readonly) int32_t format;

- (instancetype)init;
- (instancetype)initWithPixelFormat:(FFMpegAVFramePixelFormat)pixelFormat width:(int32_t)width height:(int32_t)height;

- (void *)impl;

@end

NS_ASSUME_NONNULL_END
