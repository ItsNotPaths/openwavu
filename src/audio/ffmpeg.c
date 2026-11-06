// The importer's audio over libavcodec: a game codec to 16-bit samples, and 16-bit samples to a FLAC file.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/common.h>

enum { CODEC_PS_ADPCM, CODEC_ATRAC3_PLUS };
enum { STREAMINFO_SIZE = 34, FLAC_HEADER_SIZE = 8 + STREAMINFO_SIZE };  // "fLaC", block header, STREAMINFO

typedef struct {
    uint8_t *data;
    size_t size, capacity;
} Buffer;

static bool append(Buffer *buffer, const void *data, size_t size) {
    if (buffer->size + size > buffer->capacity) {
        size_t capacity = buffer->capacity ? buffer->capacity : 1 << 16;
        while (capacity < buffer->size + size) capacity *= 2;
        uint8_t *grown = realloc(buffer->data, capacity);
        if (grown == NULL) return false;
        buffer->data = grown;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->size, data, size);
    buffer->size += size;
    return true;
}

// One sample of any decoder output as 16 bits.
static int16_t sample_at(const AVFrame *frame, int channel, int index, int channels) {
    bool planar = av_sample_fmt_is_planar(frame->format);
    const uint8_t *plane = frame->extended_data[planar ? channel : 0];
    int at = planar ? index : index * channels + channel;
    switch (av_get_packed_sample_fmt(frame->format)) {
    case AV_SAMPLE_FMT_S16: return ((const int16_t *)plane)[at];
    case AV_SAMPLE_FMT_FLT: return av_clip_int16(lrintf(((const float *)plane)[at] * 32768.0f));
    default: return 0;
    }
}

static bool take_frames(AVCodecContext *context, AVFrame *frame, Buffer *samples, int channels) {
    while (avcodec_receive_frame(context, frame) == 0) {
        for (int index = 0; index < frame->nb_samples; index++)
            for (int channel = 0; channel < channels; channel++) {
                int16_t sample = sample_at(frame, channel, index, channels);
                if (!append(samples, &sample, sizeof sample)) return false;
            }
    }
    return true;
}

// block: bytes per packet (ATRAC3plus: the RIFF block align). samples: interleaved, free with ow_audio_free.
int ow_audio_decode(int codec, int channels, int rate, int block, const uint8_t *data, size_t size, int16_t **samples,
                    size_t *frames) {
    const AVCodec *decoder = avcodec_find_decoder(codec == CODEC_ATRAC3_PLUS ? AV_CODEC_ID_ATRAC3P : AV_CODEC_ID_ADPCM_PSX);
    AVCodecContext *context = decoder ? avcodec_alloc_context3(decoder) : NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Buffer out = {0};
    bool ok = context && packet && frame;
    if (ok) {
        av_channel_layout_default(&context->ch_layout, channels);
        context->sample_rate = rate;
        context->block_align = block;
        ok = avcodec_open2(context, decoder, NULL) == 0;
    }
    for (size_t at = 0; ok && at + block <= size; at += block) {
        packet->data = (uint8_t *)data + at;
        packet->size = block;
        ok = avcodec_send_packet(context, packet) == 0 && take_frames(context, frame, &out, channels);
    }
    if (ok) ok = avcodec_send_packet(context, NULL) == 0 && take_frames(context, frame, &out, channels);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    if (!ok) {
        free(out.data);
        return 0;
    }
    *samples = (int16_t *)out.data;
    *frames = out.size / (sizeof(int16_t) * channels);
    return 1;
}

static bool take_packets(AVCodecContext *context, AVPacket *packet, Buffer *file) {
    while (avcodec_receive_packet(context, packet) == 0) {
        bool appended = append(file, packet->data, packet->size);
        av_packet_unref(packet);
        if (!appended) return false;
    }
    return true;
}

// samples: interleaved. file: a whole .flac, free with ow_audio_free.
int ow_audio_flac(const int16_t *samples, size_t frames, int channels, int rate, uint8_t **file, size_t *size) {
    const AVCodec *encoder = avcodec_find_encoder(AV_CODEC_ID_FLAC);
    AVCodecContext *context = encoder ? avcodec_alloc_context3(encoder) : NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    Buffer out = {0};
    uint8_t header[FLAC_HEADER_SIZE] = {'f', 'L', 'a', 'C', 0x80, 0, 0, STREAMINFO_SIZE};  // last block, STREAMINFO
    bool ok = context && packet && frame && append(&out, header, sizeof header);
    if (ok) {
        av_channel_layout_default(&context->ch_layout, channels);
        context->sample_rate = rate;
        context->sample_fmt = AV_SAMPLE_FMT_S16;
        ok = avcodec_open2(context, encoder, NULL) == 0;
    }
    for (size_t at = 0; ok && at < frames; at += context->frame_size) {
        frame->nb_samples = (int)FFMIN((size_t)context->frame_size, frames - at);
        frame->format = AV_SAMPLE_FMT_S16;
        frame->sample_rate = rate;
        ok = av_channel_layout_copy(&frame->ch_layout, &context->ch_layout) == 0 && av_frame_get_buffer(frame, 0) == 0;
        if (ok) {
            memcpy(frame->data[0], samples + at * channels, sizeof(int16_t) * channels * frame->nb_samples);
            ok = avcodec_send_frame(context, frame) == 0 && take_packets(context, packet, &out);
        }
        av_frame_unref(frame);
    }
    // After the flush the encoder's extradata is the final STREAMINFO (sample count, MD5).
    if (ok) ok = avcodec_send_frame(context, NULL) == 0 && take_packets(context, packet, &out);
    if (ok) ok = context->extradata_size >= STREAMINFO_SIZE;
    if (ok) memcpy(out.data + 8, context->extradata, STREAMINFO_SIZE);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&context);
    if (!ok) {
        free(out.data);
        return 0;
    }
    *file = out.data;
    *size = out.size;
    return 1;
}

void ow_audio_free(void *pointer) { free(pointer); }
