//
//  Player.swift
//  SwiftPlayer
//
//  Created by Kwanghoon Choi on 2016. 8. 29..
//  Copyright © 2016년 Kwanghoon Choi. All rights reserved.
//

import Foundation
import AVFoundation
import Accelerate
import ffmpeg

public typealias PlayerProgressHandle = (_ player: Player, _ progress: Double) -> Void

public class Player: CustomDebugStringConvertible {
    
    public var debugDescription: String {
        return self.format.debugDescription
    }
    
    let path: String
    let format: SweetFormat
    public var progressHandle: PlayerProgressHandle?
    
    private var audioHelper: MediaHelper?
    private var videoQueue: Queue<VideoData>?
    
    private var playing: Bool = false
    public var isPlaying: Bool {
        return playing
    }
    private var paused: Bool = false
    public var isPaused: Bool {
        return paused
    }
    private var quit: Bool = false
    public var isFinished: Bool {
        self.decodeLock.wait()
        let finished = self.quit
        let empty = self.videoQueue?.isEmpty ?? true
        self.decodeLock.signal()
        
        return finished && empty
    }
    private var decodeQueue: DispatchQueue = DispatchQueue(label: "com.sweetplayer.player.decode")
    private let decodeLock: DispatchSemaphore = DispatchSemaphore(value: 1)
    
    public init?(path: String, progressHandle: PlayerProgressHandle? = nil) {
        self.path = path
        av_register_all()
        avformat_network_init()
        guard let format = SweetFormat(path: path) else {
            return nil
        }
        self.format = format
        self.initialize()
        self.progressHandle = progressHandle
    }
    
    private func initialize() {
        self.playVideoStreamAt = 0
        self.playAudioStreamAt = 0
        
        if let fps = self.video?.fps {
            self.videoQueue = Queue(maxQueueCount: 16, framePeriod: 1.0 / fps)
        }
        if let audio = self.audio {
            let audioHelper = MediaHelper()
            if audioHelper.setupAudio(forAudioStream: audio) {
                self.audioHelper = audioHelper
            }
        }
    }
    
    deinit {
        avformat_network_deinit()
    }
    
    public var video: SweetStream? {
        return self.format.stream(forType: AVMEDIA_TYPE_VIDEO, at: self.playVideoStreamAt)
    }
    
    public var audio: SweetStream? {
        return self.format.stream(forType: AVMEDIA_TYPE_AUDIO, at: self.playAudioStreamAt)
    }
    
    public var videoSize: CGSize {
        guard let videoStream = self.video else {
            return CGSize()
        }
        return videoStream.videoSize
    }
    
    public var fps: Double {
        return self.format.stream(forType: AVMEDIA_TYPE_VIDEO)?.fps ?? 0.0
    }
    
    public var duration: Double {
        return self.format.duration
    }
    
    public var currentTime: Double = 0 {
        didSet {
            self.progressHandle?(self, self.progress)
        }
    }
    
    public var progress: Double {
        return currentTime / duration
    }
    
    var videoStreamIndex: Int32 = -1
    var audioStreamIndex: Int32 = -1
    
    var playVideoStreamAt: Int {
        set {
            guard let stream = self.videos?[newValue] else {
                return
            }
            videoStreamIndex = stream.index
        }
        get {
            guard 0 <= videoStreamIndex, let streams = self.videos else {
                return -1
            }
            
            return streams.index(where: { $0.index == videoStreamIndex}) ?? -1
        }
    }
    var playAudioStreamAt: Int {
        set {
            guard let stream = self.audios?[newValue] else {
                return
            }
            audioStreamIndex = stream.index
        }
        get {
            guard 0 <= audioStreamIndex, let streams = self.audios else {
                return -1
            }
            
            return streams.index(where: { $0.index == audioStreamIndex}) ?? -1
        }
    }
    
    var audios: [SweetStream]? {
        return self.format.streamsByType[AVMEDIA_TYPE_AUDIO]
    }
    
    var videos: [SweetStream]? {
        return self.format.streamsByType[AVMEDIA_TYPE_VIDEO]
    }
    
    private var seeking: Bool = false
    public var isSeeking: Bool {
        var isSeeking: Bool = false
        seekingQueue.sync { [weak self] in
            isSeeking = self?.seeking ?? false
        }
        return isSeeking
    }
    private let seekingQueue: DispatchQueue = DispatchQueue(label: "com.SweetPlayer.player.seeking", qos: DispatchQoS.userInteractive)
    private func seekingLock() {
        seekingQueue.sync { [weak self] in
            self?.seeking = true
        }
    }
    private func seekingUnlock() {
        seekingQueue.sync {
            [weak self] in
            self?.seeking = false
        }
    }
    public func seek(seek: Double) {
        self.seekingLock()
        defer {
            self.seekingUnlock()
        }
        self.timestamp = 0
        self.startTime = seek
        self.videoQueue?.reset()
        self.format.streams.forEach{$0.flush()}
        self.format.seek(seek: seek)
    }
    
    public func time(fromProgress: Double) -> CFTimeInterval {
        return self.duration * fromProgress + TIME_CONSTANT
    }
    
    public func stop() {
        self.decodeLock.wait()
        self.timestamp = 0
        self.quit = true
        self.videoQueue?.reset()
        self.format.seek()
        self.audioHelper?.stop()
        self.decodeLock.signal()
    }
    
    public func start() {
        self.decodeLock.wait()
        self.quit = false
        self.audioHelper?.start()
        self.decodeLock.signal()
        self.decodeQueue.async {
            
            var packet: AVPacket = AVPacket()
            var frame: AVFrame = AVFrame()
 
            self.video?.flush()
            self.audio?.flush()

            while true {
                if self.isSeeking {
                    continue
                }
                self.decodeLock.wait()
                defer {
                    self.decodeLock.signal()
                }
                if self.quit {
                    break
                }
                if self.videoQueue?.full ?? false || self.quit {
                    continue
                }
                
                guard false == self.quit, 0 <= av_read_frame(self.format.formatContext, &packet) else {
                    break
                }
                
                let streamIndex = Int(packet.stream_index)
                guard false == self.quit, streamIndex < self.format.streams.count, self.audioStreamIndex == packet.stream_index || self.videoStreamIndex == packet.stream_index else {
                    continue
                }
                let stream = self.format.streams[streamIndex]
                switch stream.decode(&packet, frame: &frame) {
                case .err(let err):
                    print_err(err, #function)
                    return
                case .success:
                    break
                }
                switch stream.type {
                case AVMEDIA_TYPE_VIDEO:
                    guard let data = frame.videoData(stream.time_base), false == self.quit else {
                        continue
                    }
                    self.videoQueue?.append(data: data)
                case AVMEDIA_TYPE_AUDIO:
                    
                    guard let data = frame.audioData(stream.time_base), false == self.quit else {
                        continue
                    }
                    self.audioHelper?.audioPlay(data)
                default:
                    continue
                }
            }
        }
    }
    
    var timestamp: CFAbsoluteTime = 0
    var startTime: CFAbsoluteTime = 0
    var timeprogress: Double {
        let currentTimestamp = CFAbsoluteTimeGetCurrent()
        if 0 == self.timestamp {
            self.timestamp = currentTimestamp - startTime
        }
        return currentTimestamp - self.timestamp
    }

    public func requestVideoFrame() -> PlayerDecoded {
        self.decodeLock.wait()
        defer {
            self.decodeLock.signal()
        }
        let time = self.timeprogress
        if let data = self.videoQueue?.request(timestamp: time) {
            self.currentTime = data.time
            return .video(data)
        }
        return .unknown
    }
}

public enum PlayerDecoded {
    case audio(AudioData)
    case video(VideoData)
    case unknown
    case finish
}

fileprivate struct Queue<Data: MediaTimeDatable> {
    
    let maxQueueCount: Int
    let framePeriod: Double
    
    var full: Bool {
        return maxQueueCount <= self.queue.count
    }
    
    var isEmpty: Bool {
        return self.queue.count == 0
    }
    
    var queue: [Data]
    init(maxQueueCount: Int, framePeriod: Double) {
        self.maxQueueCount = maxQueueCount
        self.framePeriod = framePeriod
        self.queue = []
    }
    
    mutating func reset() {
        self.queue.removeAll(keepingCapacity: true)
    }
    
    mutating func append(data: Data) {
        self.queue.append(data)
    }
    
    mutating func request(timestamp: Double, fixFrame: Bool = false) -> Data? {
        let filtered = self.queue.filter({$0.time > timestamp - framePeriod})
        self.queue = filtered
        guard let firstData = self.queue.first else {
            return nil
        }
        if firstData.time <= timestamp + framePeriod && false == fixFrame {
            self.queue.removeFirst()
        }
        return firstData
    }
}
