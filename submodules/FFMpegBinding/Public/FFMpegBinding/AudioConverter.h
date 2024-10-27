#ifndef AudioConverter_h
#define AudioConverter_h

#import <Foundation/Foundation.h>
#import "FFMpegBinding/FFMpegAVFrame.h"
#import "FFMpegBinding/FFMpegAVSampleFormat.h"

int32_t swresampleDataSize(
                           int numberOfChannels,
                           FFMpegAVFrame* _frame,
                           FFMpegAVSampleFormat _outSampleFormat,
                           int32_t outSampleRate
                           );

#endif /* FrameConverter_h */
