//
//  FFmpegHelper.swift
//  tutorial
//
//  Created by jayios on 2016. 9. 7..
//  Copyright © 2016년 gretech. All rights reserved.
//

import Foundation
import AVFoundation

extension AVFrame {
    mutating func videoData(_ time_base: AVRational) -> VideoData? {
        
        if 0 < self.width && 0 < self.height {
            
            guard let ybuf = self.data.0 else {
                return nil
            }
            
            let lumaSize = Int(self.linesize.0 * self.height)
            let chromaSize = Int(self.linesize.1 * self.height / 2)
            let y = Data(bytes: ybuf, count: lumaSize)
            guard let ubuf = self.data.1 else {
                return nil
            }
            let u = Data(bytes: ubuf, count: chromaSize)
            guard let vbuf = self.data.2 else {
                return nil
            }
            let v = Data(bytes: vbuf, count: chromaSize)
            let pts = av_frame_get_best_effort_timestamp(&self)
            return VideoData(y: y, u: u, v: v, lumaLength: self.linesize.0, chromaLength: self.linesize.1, w: self.width, h: self.height, pts: pts, dur: self.pkt_duration, time_base: time_base)
        }
        
        return nil
    }
    
    mutating func dataCount() -> Int {
        let dataPtr = Array(UnsafeBufferPointer.init(start: &self.data.0, count: 8))
        
        return dataPtr.reduce(0, { (result, ptr) -> Int in
            return nil == ptr ? result : result + 1
        })
    }
    
    mutating func audioData(_ time_base: AVRational) -> AudioData? {
        let format = MediaHelper.audioDefaultFormat
        return AudioData(data: Data(bytes: self.data.0!, count: Int(linesize.0)), format: format, bufferSize: Int(linesize.0), sampleSize: Int(nb_samples), pts: av_frame_get_best_effort_timestamp(&self), dur: self.pkt_duration, time_base: time_base)
    }
}

extension AVFormatContext {
    mutating func streamArray(_ type: AVMediaType) -> [SweetStream] {
        var streams: [SweetStream] = []
        for i in 0..<Int32(self.nb_streams) {
            guard let s = SweetStream(format: &self, type: type, index: i) else {
                continue
            }
            streams.append(s)
        }
        return streams
    }
}

extension AVCodecContext {
    var videoSize: CGSize {
        if 0 < self.width && 0 < self.height {
            return CGSize(width: Int(self.width), height: Int(self.height))
        }
        return CGSize()
    }
}

extension AVMediaType: Hashable {
    public var hashValue: Int {
        return Int(self.rawValue)
    }
}

class SweetFormat {
    var formatContext: UnsafeMutablePointer<AVFormatContext>?
    let path: String
    fileprivate(set) var streams: [AVMediaType: [SweetStream]] = [AVMediaType:[SweetStream]]()
    init?(path: String) {
        self.path = path
        guard av_success_desc(avformat_open_input(&formatContext, path, nil, nil), "open failed -> \(path)") else {
            return nil
        }
        guard av_success_desc(avformat_find_stream_info(formatContext, nil), "find stream info") else {
            return nil
        }
        if let videos = self.formatContext?.pointee.streamArray(AVMEDIA_TYPE_VIDEO).filter({$0.open()}) {
            self.streams[AVMEDIA_TYPE_VIDEO] = videos
        }
        if let audios = self.formatContext?.pointee.streamArray(AVMEDIA_TYPE_AUDIO).filter({$0.open()}) {
            self.streams[AVMEDIA_TYPE_AUDIO] = audios
        }
        if 0 == self.streams.count {
            return nil
        }
        if let subtitles = self.formatContext?.pointee.streamArray(AVMEDIA_TYPE_SUBTITLE).filter({$0.open()}) {
            self.streams[AVMEDIA_TYPE_SUBTITLE] = subtitles
        }
    }
    
    deinit {
        avformat_close_input(&formatContext)
    }
    
    var videoSize: CGSize {
        
        guard let index = self.streams.index(forKey: AVMEDIA_TYPE_VIDEO), let stream = self.streams[index].value.first else {
            return CGSize()
        }
        
        return stream.videoSize
    }
}

class SweetStream {
    let format: UnsafeMutablePointer<AVFormatContext>
    let index: Int32
    let stream: UnsafeMutablePointer<AVStream>
    let codec: UnsafeMutablePointer<AVCodecContext>
    let type: AVMediaType
    var w: Int32 {
        return codec.pointee.width
    }
    var h: Int32 {
        return codec.pointee.height
    }
    
    var videoSize: CGSize {
        return CGSize(width: Int(w), height: Int(h))
    }
    
    var fps: Double {
        return 1.0 / av_q2d(self.stream.pointee.avg_frame_rate)
    }
    
    var time_base: AVRational {
        switch self.type {
        case AVMEDIA_TYPE_AUDIO, AVMEDIA_TYPE_VIDEO:
            return self.stream.pointee.time_base
        default:
            return AVRational()
        }
    }
    
    init?(format: UnsafeMutablePointer<AVFormatContext>?, type: AVMediaType = AVMEDIA_TYPE_UNKNOWN, index: Int32 = -1) {
        guard let f = format else {
            return nil
        }
        self.format = f
        self.type = type
        
        guard type != AVMEDIA_TYPE_UNKNOWN || 0 <= index else {
            assertionFailure("must have type or positive index.")
            return nil
        }
        if 0 <= index {
            if index >= Int32(self.format.pointee.nb_streams) {
                return nil
            }
            self.index = index
        } else {
            self.index = av_find_best_stream(format, type, -1, -1, nil, 0)
            if 0 > self.index {
                return nil
            }
        }
        guard let s = self.format.pointee.streams[Int(self.index)], s.pointee.codecpar.pointee.codec_type == type else {
            return nil
        }
        self.stream = s
        
        self.codec = self.stream.pointee.codec
        self.codec.pointee.thread_count = 2
        self.codec.pointee.thread_type = FF_THREAD_FRAME
    }
    
    func open() -> Bool {
        guard let decoder = avcodec_find_decoder(self.codec.pointee.codec_id) else {
            return false
        }
        guard 0 <= avcodec_open2(self.codec, decoder, nil) else {
            return false
        }
        return true
    }
    
    enum SweetDecodeResult {
        case err(Int32)
        case success
        case pass
    }
    
    func decode(_ pkt: UnsafeMutablePointer<AVPacket>, frame: UnsafeMutablePointer<AVFrame>) -> SweetDecodeResult{
        
        var ret = avcodec_send_packet(self.codec, pkt)
        if 0 > ret && ret != AVERROR_CONVERT(EAGAIN) && false == IS_AVERROR_EOF(ret){
            return .err(ret)
        }
        ret = avcodec_receive_frame(self.codec, frame)
        if ret == AVERROR_CONVERT(EAGAIN) {
            return .pass
        }
        if 0 > ret && false == IS_AVERROR_EOF(ret) {
            return .err(ret)
        }
        guard let filter = self.filter else {
            return .success
        }
        switch filter.applyFilter(frame) {
        case .success:
            return .success
        case .continue, .noMoreFrames:
            return .pass
        case .failed:
            return .err(-1)
        default:
            break
        }
        return .success
    }
    
    var filter: AVFilterHelper? = nil
    func setupFilter(
        _ outSampleRate: Int32,
        outSampleFmt: AVSampleFormat,
        outChannels: Int32) -> Bool{
        
        let inSampleRate: Int32 = self.stream.pointee.codecpar.pointee.sample_rate
        let inSampleFmt: AVSampleFormat = AVSampleFormat(rawValue: self.stream.pointee.codecpar.pointee.format)
        let inTimeBase: AVRational = self.time_base
        let inChannelLayout: UInt64 = self.stream.pointee.codecpar.pointee.channel_layout
        let inChannels: Int32 = self.stream.pointee.codecpar.pointee.channels
        
        self.filter = AVFilterHelper()
        //TODO: setup filter
        var sbuf = [Int8](repeating: 0, count: 64)
        av_get_channel_layout_string(&sbuf, Int32(sbuf.count), inChannels, inChannelLayout)
        let inChannelLayoutString = String(cString: sbuf)
        guard 0 < inChannelLayoutString.lengthOfBytes(using: .utf8) else {
            return false
        }
        sbuf = [Int8](repeating: 0, count: 64)
        let outChannelLayout = av_get_default_channel_layout(outChannels)
        av_get_channel_layout_string(&sbuf, Int32(sbuf.count), outChannels, UInt64(outChannelLayout))
        let outChannelLayoutString = String(cString: sbuf)
        guard 0 < outChannelLayoutString.lengthOfBytes(using: .utf8) else {
            return false
        }
        let inTimeBaseStr = "\(inTimeBase.num)/\(inTimeBase.den)"
        let inSampleFormatStr = String(cString: av_get_sample_fmt_name(inSampleFmt))
        let outSampleFormatStr = String(cString: av_get_sample_fmt_name(outSampleFmt))
        
        return filter?.setup(
            format,
            audioStream: stream,
            abuffer: "sample_rate=\(inSampleRate):sample_fmt=\(inSampleFormatStr):time_base=\(inTimeBaseStr):channels=\(inChannels):channel_layout=\(inChannelLayoutString)",
            aformat: "sample_rates=\(outSampleRate):sample_fmts=\(outSampleFormatStr):channel_layouts=\(outChannelLayoutString)") ?? false
    }
}
