using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using FFmpeg.AutoGen;
using MuurMusic.Audio.Decoding;
using MuurMusic.Core.Models;
using MuurMusic.Core.Sources;
using MuurMusic.Core.Tags;

namespace MuurMusic.Audio.FFmpeg;

/// <summary>
/// FFmpeg-based decoder for every format FFmpeg supports (FLAC, ALAC, WAV, AIFF, APE, WavPack, TAK, MP3, AAC, Opus, Vorbis,
/// WMA, DSF/DFF, tracker modules via libopenmpt, ...). Opens local/UNC files, HTTP(S) URLs (with headers and reconnect) and
/// arbitrary random-access streams through a custom AVIO context. Output is interleaved float, resampled with swresample.
/// </summary>
public sealed unsafe class FFmpegDecoder : IAudioDecoder
{
    private const int AvioBufferSize = 1 << 16;
    private const int SeekSet = 0, SeekCur = 1, SeekEnd = 2, AvseekSize = 0x10000, AvseekForce = 0x20000;

    private AVFormatContext* _fmt;
    private AVCodecContext* _ctx;
    private SwrContext* _swr;
    private AVPacket* _pkt;
    private AVFrame* _frame;
    private AVIOContext* _avio;
    private AVStream* _stream;
    private int _streamIndex;

    private Stream? _ioStream;
    private avio_alloc_context_read_packet? _readDelegate;
    private avio_alloc_context_seek? _seekDelegate;
    private AVIOInterruptCB_callback? _interruptDelegate;

    private volatile bool _abort;
    private bool _draining;
    private bool _eof;
    private bool _swrFlushed;
    private int _consecutiveErrors;

    private int _outRate, _outChannels;
    private int _swrInRate, _swrInChannels;
    private AVSampleFormat _swrInFormat = AVSampleFormat.AV_SAMPLE_FMT_NONE;
    private readonly bool _highQualityResampler;

    private float[] _pending = new float[8192];
    private int _pendingOffset, _pendingCount; // in samples (not frames)
    private long _skipFrames;      // output frames still to drop after a seek
    private long _seekTargetOut = -1; // output-frame position requested by the last seek
    private bool _disposed;

    private FFmpegDecoder(bool highQualityResampler) => _highQualityResampler = highQualityResampler;

    public AudioStreamInfo Info { get; private set; } = new();
    public int OutputSampleRate => _outRate;
    public int OutputChannels => _outChannels;
    public bool CanSeek { get; private set; }
    public string? Error { get; private set; }
    public IReadOnlyDictionary<string, string> Tags { get; private set; } = new Dictionary<string, string>();
    public byte[]? AttachedPicture { get; private set; }

    /// <summary>Opens a <see cref="MediaLocation"/> (file, URL or stream).</summary>
    public static FFmpegDecoder Open(MediaLocation location, bool highQualityResampler = true, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(location);
        return location.Kind switch
        {
            MediaLocationKind.File => OpenUrl(location.Path!, null, highQualityResampler, ct),
            MediaLocationKind.Url => OpenUrl(location.Url!, location.Headers, highQualityResampler, ct),
            _ => OpenStream(new RandomAccessStream(location.OpenAt!, location.Length), location.FileName, highQualityResampler, ct)
        };
    }

    public static FFmpegDecoder OpenFile(string path, bool highQualityResampler = true) => OpenUrl(path, null, highQualityResampler, default);

    public static FFmpegDecoder OpenUrl(string url, IReadOnlyDictionary<string, string>? headers, bool highQualityResampler, CancellationToken ct)
    {
        FFmpegLoader.EnsureLoaded();
        var d = new FFmpegDecoder(highQualityResampler);
        try
        {
            d.OpenInput(url, headers, null, ct);
            return d;
        }
        catch
        {
            d.Dispose();
            throw;
        }
    }

    /// <summary>Opens a seekable (or forward-only) stream; <paramref name="fileName"/> helps format probing.</summary>
    public static FFmpegDecoder OpenStream(Stream stream, string? fileName, bool highQualityResampler = true, CancellationToken ct = default)
    {
        FFmpegLoader.EnsureLoaded();
        var d = new FFmpegDecoder(highQualityResampler);
        try
        {
            d.OpenInput(fileName ?? "stream", null, stream, ct);
            return d;
        }
        catch
        {
            d.Dispose();
            throw;
        }
    }

    private void OpenInput(string url, IReadOnlyDictionary<string, string>? headers, Stream? stream, CancellationToken ct)
    {
        using var reg = ct.Register(() => _abort = true);
        _fmt = ffmpeg.avformat_alloc_context();
        if (_fmt == null) throw new OutOfMemoryException();
        _interruptDelegate = _ => _abort ? 1 : 0;
        _fmt->interrupt_callback = new AVIOInterruptCB
        {
            callback = new AVIOInterruptCB_callback_func { Pointer = Marshal.GetFunctionPointerForDelegate(_interruptDelegate) }
        };

        AVDictionary* options = null;
        var isNetwork = url.StartsWith("http://", StringComparison.OrdinalIgnoreCase) || url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
        if (stream is not null)
        {
            _ioStream = stream;
            _readDelegate = ReadPacket;
            _seekDelegate = SeekPacket;
            var buffer = (byte*)ffmpeg.av_malloc(AvioBufferSize);
            _avio = ffmpeg.avio_alloc_context(buffer, AvioBufferSize, 0, null,
                new avio_alloc_context_read_packet_func { Pointer = Marshal.GetFunctionPointerForDelegate(_readDelegate) },
                default,
                stream.CanSeek ? new avio_alloc_context_seek_func { Pointer = Marshal.GetFunctionPointerForDelegate(_seekDelegate) } : default);
            if (_avio == null) throw new OutOfMemoryException();
            _avio->seekable = stream.CanSeek ? ffmpeg.AVIO_SEEKABLE_NORMAL : 0;
            _fmt->pb = _avio;
            _fmt->flags |= ffmpeg.AVFMT_FLAG_CUSTOM_IO;
        }
        else if (isNetwork)
        {
            ffmpeg.av_dict_set(&options, "user_agent", HttpClientNames.UserAgent, 0);
            ffmpeg.av_dict_set(&options, "reconnect", "1", 0);
            ffmpeg.av_dict_set(&options, "reconnect_on_network_error", "1", 0);
            ffmpeg.av_dict_set(&options, "reconnect_delay_max", "10", 0);
            ffmpeg.av_dict_set(&options, "rw_timeout", "20000000", 0);
            ffmpeg.av_dict_set(&options, "multiple_requests", "1", 0);
            if (headers is { Count: > 0 })
            {
                var sb = new StringBuilder();
                foreach (var (k, v) in headers)
                {
                    if (k.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)) { ffmpeg.av_dict_set(&options, "user_agent", v, 0); continue; }
                    sb.Append(k).Append(": ").Append(v).Append("\r\n");
                }
                if (sb.Length > 0) ffmpeg.av_dict_set(&options, "headers", sb.ToString(), 0);
            }
        }

        var fmt = _fmt;
        var openUrl = stream is not null ? null : url;
        var ret = ffmpeg.avformat_open_input(&fmt, openUrl, null, &options);
        ffmpeg.av_dict_free(&options);
        if (ret < 0)
        {
            _fmt = null; // avformat_open_input frees the context on failure
            if (_abort) throw new OperationCanceledException(ct);
            throw new AudioDecoderException($"Cannot open {DisplayName(url)}: {FFmpegLoader.ErrorString(ret)}");
        }
        _fmt = fmt;

        ret = ffmpeg.avformat_find_stream_info(_fmt, null);
        if (ret < 0 && _abort) throw new OperationCanceledException(ct);

        AVCodec* codec = null;
        _streamIndex = ffmpeg.av_find_best_stream(_fmt, AVMediaType.AVMEDIA_TYPE_AUDIO, -1, -1, &codec, 0);
        if (_streamIndex < 0) throw new AudioDecoderException($"{DisplayName(url)} contains no audio stream.");
        _stream = _fmt->streams[_streamIndex];
        if (codec == null) codec = ffmpeg.avcodec_find_decoder(_stream->codecpar->codec_id);
        if (codec == null) throw new AudioDecoderException($"No decoder for codec {ffmpeg.avcodec_get_name(_stream->codecpar->codec_id)}.");

        // Discard other streams (cover art, video) so the demuxer does not waste time on them.
        for (var i = 0; i < _fmt->nb_streams; i++)
            if (i != _streamIndex) _fmt->streams[i]->discard = AVDiscard.AVDISCARD_ALL;

        _ctx = ffmpeg.avcodec_alloc_context3(codec);
        if (_ctx == null) throw new OutOfMemoryException();
        Check(ffmpeg.avcodec_parameters_to_context(_ctx, _stream->codecpar), "avcodec_parameters_to_context");
        _ctx->pkt_timebase = _stream->time_base;
        Check(ffmpeg.avcodec_open2(_ctx, codec, null), "avcodec_open2");

        _pkt = ffmpeg.av_packet_alloc();
        _frame = ffmpeg.av_frame_alloc();

        var tags = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        FFmpegLoader.ReadDict(_fmt->metadata, tags);
        FFmpegLoader.ReadDict(_stream->metadata, tags);
        Tags = tags;
        for (var i = 0; i < _fmt->nb_streams; i++)
        {
            var s = _fmt->streams[i];
            if ((s->disposition & ffmpeg.AV_DISPOSITION_ATTACHED_PIC) != 0 && s->attached_pic.size > 0)
            {
                AttachedPicture = new ReadOnlySpan<byte>(s->attached_pic.data, s->attached_pic.size).ToArray();
                break;
            }
        }

        var codecId = _stream->codecpar->codec_id;
        var codecName = ffmpeg.avcodec_get_name(codecId) ?? "unknown";
        var isDsd = codecId is AVCodecID.AV_CODEC_ID_DSD_LSBF or AVCodecID.AV_CODEC_ID_DSD_MSBF or AVCodecID.AV_CODEC_ID_DSD_LSBF_PLANAR or AVCodecID.AV_CODEC_ID_DSD_MSBF_PLANAR;
        var bits = _stream->codecpar->bits_per_raw_sample;
        if (bits <= 0 && codecName.StartsWith("pcm_", StringComparison.Ordinal)) bits = _stream->codecpar->bits_per_coded_sample;
        if (isDsd) bits = 1;
        var duration = TimeSpan.Zero;
        if (_stream->duration > 0 && _stream->duration != ffmpeg.AV_NOPTS_VALUE)
            duration = TimeSpan.FromSeconds(_stream->duration * ffmpeg.av_q2d(_stream->time_base));
        else if (_fmt->duration > 0 && _fmt->duration != ffmpeg.AV_NOPTS_VALUE)
            duration = TimeSpan.FromSeconds(_fmt->duration / (double)ffmpeg.AV_TIME_BASE);
        var bitrate = _stream->codecpar->bit_rate > 0 ? _stream->codecpar->bit_rate : _fmt->bit_rate;
        var codecLabel = MapCodec(codecName);
        Info = new AudioStreamInfo
        {
            SampleRate = _ctx->sample_rate,
            Channels = Math.Max(1, _ctx->ch_layout.nb_channels),
            BitDepth = AudioFormats.IsLosslessCodec(codecLabel) || isDsd ? Math.Max(0, bits) : 0,
            Codec = codecLabel,
            Container = _fmt->iformat != null ? Marshal.PtrToStringUTF8((IntPtr)_fmt->iformat->name) : null,
            Duration = duration,
            BitrateKbps = (int)(bitrate / 1000),
            IsDsd = isDsd,
            IsLossless = AudioFormats.IsLosslessCodec(codecLabel) || isDsd
        };
        CanSeek = stream?.CanSeek ?? (_fmt->pb == null || _fmt->pb->seekable != 0 || duration > TimeSpan.Zero);
        _outRate = Info.SampleRate;
        _outChannels = Info.Channels;
    }

    /// <summary>Maps FFmpeg codec names to the codec labels used in the library (FLAC, ALAC, MP3, AAC, ...).</summary>
    internal static string MapCodec(string ffName) => ffName switch
    {
        "flac" => "FLAC",
        "alac" => "ALAC",
        "mp3" or "mp3float" or "mp2" or "mp1" => ffName == "mp2" ? "MP2" : "MP3",
        "aac" or "aac_latm" => "AAC",
        "opus" => "Opus",
        "vorbis" => "Vorbis",
        "ape" => "APE",
        "wavpack" => "WavPack",
        "tak" => "TAK",
        "tta" => "TTA",
        "mlp" => "MLP",
        "truehd" => "TrueHD",
        "ac3" => "AC3",
        "eac3" => "E-AC3",
        "dts" => "DTS",
        "wmav1" or "wmav2" => "WMA",
        "wmapro" => "WMA Pro",
        "wmalossless" => "WMA Lossless",
        "musepack7" or "musepack8" => "Musepack",
        "speex" => "Speex",
        "dsd_lsbf" or "dsd_msbf" or "dsd_lsbf_planar" or "dsd_msbf_planar" => "DSD",
        "libopenmpt" => "Module",
        _ when ffName.StartsWith("pcm_", StringComparison.Ordinal) => "PCM",
        _ when ffName.StartsWith("adpcm", StringComparison.Ordinal) => "ADPCM",
        _ => ffName.ToUpperInvariant()
    };

    private static string DisplayName(string url) => url.StartsWith("http", StringComparison.OrdinalIgnoreCase) ? SourceUris.FileNameOf(url) : Path.GetFileName(url);

    private int ReadPacket(void* opaque, byte* buf, int size)
    {
        try
        {
            if (_abort) return ffmpeg.AVERROR_EXIT;
            var n = _ioStream!.Read(new Span<byte>(buf, size));
            return n == 0 ? ffmpeg.AVERROR_EOF : n;
        }
        catch (Exception ex)
        {
            Error ??= ex.Message;
            return ffmpeg.AVERROR_EOF;
        }
    }

    private long SeekPacket(void* opaque, long offset, int whence)
    {
        try
        {
            var s = _ioStream!;
            whence &= ~AvseekForce;
            if (whence == AvseekSize) return s.CanSeek ? s.Length : -1;
            if (!s.CanSeek) return -1;
            return whence switch
            {
                SeekSet => s.Seek(offset, SeekOrigin.Begin),
                SeekCur => s.Seek(offset, SeekOrigin.Current),
                SeekEnd => s.Seek(offset, SeekOrigin.End),
                _ => -1
            };
        }
        catch (Exception)
        {
            return -1;
        }
    }

    public void SetOutputFormat(int sampleRate, int channels)
    {
        if (sampleRate <= 0) sampleRate = Info.SampleRate;
        if (channels <= 0) channels = Info.Channels;
        if (sampleRate == _outRate && channels == _outChannels && _swr != null) return;
        _outRate = sampleRate;
        _outChannels = channels;
        FreeResampler();
        _pendingOffset = _pendingCount = 0;
    }

    private void FreeResampler()
    {
        if (_swr != null)
        {
            var swr = _swr;
            ffmpeg.swr_free(&swr);
            _swr = null;
        }
        _swrInFormat = AVSampleFormat.AV_SAMPLE_FMT_NONE;
        _swrInRate = _swrInChannels = 0;
        _swrFlushed = false;
    }

    private void EnsureResampler(AVFrame* frame)
    {
        var fmt = (AVSampleFormat)frame->format;
        var channels = frame->ch_layout.nb_channels;
        if (_swr != null && fmt == _swrInFormat && frame->sample_rate == _swrInRate && channels == _swrInChannels) return;
        FreeResampler();
        AVChannelLayout inLayout, outLayout;
        if (frame->ch_layout.order == AVChannelOrder.AV_CHANNEL_ORDER_UNSPEC || channels <= 0)
            ffmpeg.av_channel_layout_default(&inLayout, Math.Max(1, channels));
        else
            Check(ffmpeg.av_channel_layout_copy(&inLayout, &frame->ch_layout), "av_channel_layout_copy");
        ffmpeg.av_channel_layout_default(&outLayout, _outChannels);
        SwrContext* swr = null;
        Check(ffmpeg.swr_alloc_set_opts2(&swr, &outLayout, AVSampleFormat.AV_SAMPLE_FMT_FLT, _outRate, &inLayout, fmt, frame->sample_rate, 0, null), "swr_alloc_set_opts2");
        if (_highQualityResampler && frame->sample_rate != _outRate)
        {
            // Prefer the SoX resampler when the FFmpeg build has it; otherwise use a long windowed-sinc filter.
            if (ffmpeg.av_opt_set(swr, "resampler", "soxr", 0) >= 0)
                ffmpeg.av_opt_set_int(swr, "precision", 28, 0);
            else
            {
                ffmpeg.av_opt_set_int(swr, "filter_size", 64, 0);
                ffmpeg.av_opt_set_int(swr, "phase_shift", 12, 0);
                ffmpeg.av_opt_set_double(swr, "cutoff", 0.97, 0);
            }
        }
        // Down-mix without clipping-prone normalization surprises: keep unity gain on the main channels.
        ffmpeg.av_opt_set_int(swr, "clip_protection", 0, 0);
        var ret = ffmpeg.swr_init(swr);
        if (ret < 0 && _highQualityResampler)
        {
            ffmpeg.swr_free(&swr);
            swr = null;
            Check(ffmpeg.swr_alloc_set_opts2(&swr, &outLayout, AVSampleFormat.AV_SAMPLE_FMT_FLT, _outRate, &inLayout, fmt, frame->sample_rate, 0, null), "swr_alloc_set_opts2");
            ret = ffmpeg.swr_init(swr);
        }
        ffmpeg.av_channel_layout_uninit(&inLayout);
        ffmpeg.av_channel_layout_uninit(&outLayout);
        if (ret < 0)
        {
            ffmpeg.swr_free(&swr);
            throw new AudioDecoderException($"Resampler init failed: {FFmpegLoader.ErrorString(ret)}");
        }
        _swr = swr;
        _swrInFormat = fmt;
        _swrInRate = frame->sample_rate;
        _swrInChannels = channels;
    }

    public int Read(Span<float> buffer)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var channels = _outChannels;
        var framesWanted = buffer.Length / channels;
        var written = 0;
        while (written < framesWanted)
        {
            if (_pendingCount > 0)
            {
                var frames = Math.Min(_pendingCount / channels, framesWanted - written);
                _pending.AsSpan(_pendingOffset, frames * channels).CopyTo(buffer.Slice(written * channels));
                _pendingOffset += frames * channels;
                _pendingCount -= frames * channels;
                written += frames;
                continue;
            }
            if (_eof || _abort) break;
            if (!DecodeNext()) break;
        }
        return written;
    }

    /// <summary>Decodes the next frame into the pending buffer. Returns false at the end of the stream.</summary>
    private bool DecodeNext()
    {
        while (true)
        {
            var ret = ffmpeg.avcodec_receive_frame(_ctx, _frame);
            if (ret == 0)
            {
                _consecutiveErrors = 0;
                try { ConvertFrame(); }
                finally { ffmpeg.av_frame_unref(_frame); }
                if (_pendingCount > 0) return true;
                continue;
            }
            if (ret == ffmpeg.AVERROR_EOF)
            {
                FlushResampler();
                _eof = true;
                return _pendingCount > 0;
            }
            if (ret != -ffmpeg.EAGAIN)
            {
                if (++_consecutiveErrors > 50)
                {
                    Error = $"Decoding failed: {FFmpegLoader.ErrorString(ret)}";
                    _eof = true;
                    return false;
                }
                continue;
            }
            if (_draining)
            {
                FlushResampler();
                _eof = true;
                return _pendingCount > 0;
            }
            // Feed the decoder.
            ret = ffmpeg.av_read_frame(_fmt, _pkt);
            if (ret < 0)
            {
                if (ret != ffmpeg.AVERROR_EOF && !_abort && (_fmt->pb == null || ffmpeg.avio_feof(_fmt->pb) == 0))
                    Error ??= $"Read error: {FFmpegLoader.ErrorString(ret)}";
                if (_abort) return false;
                ffmpeg.avcodec_send_packet(_ctx, null);
                _draining = true;
                continue;
            }
            if (_pkt->stream_index != _streamIndex)
            {
                ffmpeg.av_packet_unref(_pkt);
                continue;
            }
            ret = ffmpeg.avcodec_send_packet(_ctx, _pkt);
            ffmpeg.av_packet_unref(_pkt);
            if (ret < 0 && ret != -ffmpeg.EAGAIN && ++_consecutiveErrors > 50)
            {
                Error = $"Decoding failed: {FFmpegLoader.ErrorString(ret)}";
                _eof = true;
                return false;
            }
        }
    }

    private void ConvertFrame()
    {
        if (_frame->nb_samples <= 0) return;
        EnsureResampler(_frame);
        var outCount = ffmpeg.swr_get_out_samples(_swr, _frame->nb_samples) + 32;
        EnsurePending(outCount * _outChannels);
        int converted;
        fixed (float* p = _pending)
        {
            var outPtr = (byte*)p;
            converted = ffmpeg.swr_convert(_swr, &outPtr, outCount, _frame->extended_data, _frame->nb_samples);
        }
        if (converted < 0) throw new AudioDecoderException($"Resampling failed: {FFmpegLoader.ErrorString(converted)}");
        _pendingOffset = 0;
        _pendingCount = converted * _outChannels;

        if (_seekTargetOut >= 0)
        {
            // Sample-accurate seek: drop output frames that precede the requested position.
            var pts = _frame->best_effort_timestamp != ffmpeg.AV_NOPTS_VALUE ? _frame->best_effort_timestamp : _frame->pts;
            if (pts != ffmpeg.AV_NOPTS_VALUE)
            {
                var start = _stream->start_time != ffmpeg.AV_NOPTS_VALUE ? _stream->start_time : 0;
                var frameStartOut = (long)Math.Round((pts - start) * ffmpeg.av_q2d(_stream->time_base) * _outRate);
                _skipFrames = Math.Max(0, _seekTargetOut - frameStartOut);
            }
            else _skipFrames = 0;
            _seekTargetOut = -1;
        }
        if (_skipFrames > 0)
        {
            var drop = (int)Math.Min(_skipFrames, converted);
            _pendingOffset = drop * _outChannels;
            _pendingCount -= drop * _outChannels;
            _skipFrames -= drop;
        }
    }

    private void FlushResampler()
    {
        if (_swr == null || _swrFlushed) return;
        _swrFlushed = true;
        var outCount = (int)ffmpeg.swr_get_delay(_swr, _outRate) + 64;
        EnsurePending(outCount * _outChannels);
        int converted;
        fixed (float* p = _pending)
        {
            var outPtr = (byte*)p;
            converted = ffmpeg.swr_convert(_swr, &outPtr, outCount, null, 0);
        }
        if (converted > 0)
        {
            _pendingOffset = 0;
            _pendingCount = converted * _outChannels;
            if (_skipFrames > 0)
            {
                var drop = (int)Math.Min(_skipFrames, converted);
                _pendingOffset = drop * _outChannels;
                _pendingCount -= drop * _outChannels;
                _skipFrames -= drop;
            }
        }
    }

    private void EnsurePending(int samples)
    {
        if (_pending.Length < samples) _pending = new float[Math.Max(samples, _pending.Length * 2)];
    }

    public void Seek(TimeSpan position)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (position < TimeSpan.Zero) position = TimeSpan.Zero;
        var tb = _stream->time_base;
        var start = _stream->start_time != ffmpeg.AV_NOPTS_VALUE ? _stream->start_time : 0;
        var ts = start + (long)(position.TotalSeconds / ffmpeg.av_q2d(tb));
        var ret = ffmpeg.av_seek_frame(_fmt, _streamIndex, ts, ffmpeg.AVSEEK_FLAG_BACKWARD);
        if (ret < 0)
        {
            var global = (long)(position.TotalSeconds * ffmpeg.AV_TIME_BASE);
            ret = ffmpeg.avformat_seek_file(_fmt, -1, long.MinValue, global, global, 0);
        }
        if (ret < 0) throw new AudioDecoderException($"Seek failed: {FFmpegLoader.ErrorString(ret)}");
        ffmpeg.avcodec_flush_buffers(_ctx);
        FreeResampler();
        _pendingOffset = _pendingCount = 0;
        _eof = _draining = false;
        _skipFrames = 0;
        _seekTargetOut = (long)Math.Round(position.TotalSeconds * _outRate);
        Error = null;
    }

    public void Abort() => _abort = true;

    /// <summary>Probes a file or URL without decoding audio.</summary>
    public static MediaProbeResult Probe(string location, IReadOnlyDictionary<string, string>? headers = null, CancellationToken ct = default)
    {
        using var d = OpenUrl(location, headers, false, ct);
        return d.ToProbeResult();
    }

    public MediaProbeResult ToProbeResult()
    {
        static double? Gain(IReadOnlyDictionary<string, string> tags, string key)
        {
            if (!tags.TryGetValue(key, out var v)) return null;
            var s = v.Replace("dB", "", StringComparison.OrdinalIgnoreCase).Trim();
            return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var g) ? g : null;
        }
        return new MediaProbeResult
        {
            Duration = Info.Duration,
            SampleRate = Info.IsDsd ? Info.SampleRate * 8 : Info.SampleRate,
            Channels = Info.Channels,
            BitDepth = Info.BitDepth,
            BitrateKbps = Info.BitrateKbps,
            Codec = Info.Codec,
            Container = Info.Container,
            Tags = Tags,
            Artwork = AttachedPicture,
            ReplayGainTrackGain = Gain(Tags, "REPLAYGAIN_TRACK_GAIN"),
            ReplayGainTrackPeak = Gain(Tags, "REPLAYGAIN_TRACK_PEAK"),
            ReplayGainAlbumGain = Gain(Tags, "REPLAYGAIN_ALBUM_GAIN"),
            ReplayGainAlbumPeak = Gain(Tags, "REPLAYGAIN_ALBUM_PEAK")
        };
    }

    private static void Check(int ret, string what)
    {
        if (ret < 0) throw new AudioDecoderException($"{what} failed: {FFmpegLoader.ErrorString(ret)}");
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _abort = true;
        FreeResampler();
        if (_frame != null) { var f = _frame; ffmpeg.av_frame_free(&f); _frame = null; }
        if (_pkt != null) { var p = _pkt; ffmpeg.av_packet_free(&p); _pkt = null; }
        if (_ctx != null) { var c = _ctx; ffmpeg.avcodec_free_context(&c); _ctx = null; }
        if (_fmt != null) { var f = _fmt; ffmpeg.avformat_close_input(&f); _fmt = null; }
        if (_avio != null)
        {
            ffmpeg.av_freep(&_avio->buffer);
            var a = _avio;
            ffmpeg.avio_context_free(&a);
            _avio = null;
        }
        _ioStream?.Dispose();
        _ioStream = null;
        GC.KeepAlive(_readDelegate);
        GC.KeepAlive(_seekDelegate);
        GC.KeepAlive(_interruptDelegate);
    }
}
