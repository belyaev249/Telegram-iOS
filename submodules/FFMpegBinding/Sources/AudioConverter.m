#include "libswresample/swresample.h"
#include "libavutil/avutil.h"

#import <FFMpegBinding/AudioConverter.h>
#import <FFMpegBinding/FFMpegAVFrame.h>
#import <FFMpegBinding/FFMpegAVSampleFormat.h>

int32_t swresampleDataSize(
                           int numberOfChannels,
                           FFMpegAVFrame* _frame,
                           FFMpegAVSampleFormat _outSampleFormat,
                           int32_t outSampleRate
                           )
{
    AVFrame* frame = [_frame impl];
    
    uint64_t inChannel = frame->channel_layout;
    uint64_t outChannel = inChannel;
    
    enum AVSampleFormat outSampleFormat = (enum AVSampleFormat)_outSampleFormat;
    
    enum AVSampleFormat inSampleFormat = frame->format;
    int32_t inSampleRate = frame->sample_rate;
    
    SwrContext* s;
    s = swr_alloc_set_opts(nil, outChannel, outSampleFormat, outSampleRate, inChannel, inSampleFormat, inSampleRate, 0, nil);
    
    if (s == nil) {
        swr_free(&s);
        return 0;
    }
    
    int outSamples = swr_get_out_samples(s, frame->nb_samples);
    
    int32_t bufferSize[1];
    
    av_samples_get_buffer_size(bufferSize, numberOfChannels, outSamples, outSampleFormat, 1);
    
    int32_t dataSize = bufferSize[0];
    
    swr_free(&s);
    
    return dataSize;
}
