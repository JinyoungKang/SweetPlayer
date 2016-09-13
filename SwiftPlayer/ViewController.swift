//
//  ViewController.swift
//  SwiftPlayer
//
//  Created by Kwanghoon Choi on 2016. 8. 29..
//  Copyright © 2016년 Kwanghoon Choi. All rights reserved.
//

import UIKit
import SDL
import AVFoundation

class ViewController: UIViewController {
    
    var path: String? = nil
    var player: Player? = nil
    
    var displayLink: CADisplayLink? = nil
    
    deinit {
        print("view finished")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        let prevIO = UIApplication.shared.statusBarOrientation
        if UIInterfaceOrientationIsPortrait(prevIO) {
            UIDevice.current.setValue(UIDeviceOrientation.landscapeLeft.rawValue, forKey: "orientation")
        }
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if let path = self.path, 0 < path.lengthOfBytes(using: .utf8) {
            self.player = Player(path: path)
            
        }
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        print("\(String(describing: self))-\(#function)-\(self.player)")
        super.viewDidDisappear(animated)
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    var start: Double = 0
    func update(link: CADisplayLink) {
        if 0 == start {
            start = link.timestamp
        }
        
    }
    
    //MARK: - setupSDL
    var window: OpaquePointer!
    var renderer: OpaquePointer!
    var texture: OpaquePointer!
    
    var videoRect: SDL_Rect = SDL_Rect()
    var dst: SDL_Rect = SDL_Rect()
    lazy var eventQueue: DispatchQueue? = DispatchQueue(label: "sdl.event.queue")
    
    private func setupSDL(player: Player) -> Bool {
        
        SDL_SetMainReady()
        
        let screenSize = UIScreen.main.bounds.size
        
        guard 0 <= SDL_Init(UInt32(SDL_INIT_AUDIO | SDL_INIT_VIDEO)) else {
            print("SDL_Init: " + String(cString: SDL_GetError()))
            return false
        }
        
        guard let w = SDL_CreateWindow("SwiftPlayer", 0, 0, Int32(screenSize.width), Int32(screenSize.height), SDL_WINDOW_OPENGL.rawValue | SDL_WINDOW_SHOWN.rawValue | SDL_WINDOW_BORDERLESS.rawValue) else {
            print("SDL_CreateWindow: " + String(cString: SDL_GetError()))
            return false
        }
        
        window = w
        
        guard let r = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED.rawValue | SDL_RENDERER_TARGETTEXTURE.rawValue) else {
            print("SDL_CreateRenderer: " + String(cString: SDL_GetError()))
            return false
        }
        
        renderer = r
        
        let videoSize: CGSize = player.videoSize
        let videoRect: SDL_Rect = SDL_Rect(x: 0, y: 0, w: Int32(videoSize.width), h: Int32(videoSize.height))
        self.videoRect = videoRect
        
        let fitSize = AVMakeRect(aspectRatio: videoSize, insideRect: self.view.window?.bounds ?? CGRect())
        self.dst.x = Int32(fitSize.origin.x)
        self.dst.y = Int32(fitSize.origin.y)
        self.dst.w = Int32(fitSize.width)
        self.dst.h = Int32(fitSize.height)
        guard let t = SDL_CreateTexture(renderer, Uint32(SDL_PIXELFORMAT_IYUV), Int32(SDL_TEXTUREACCESS_TARGET.rawValue), videoRect.w, videoRect.h) else {
            print("SDL_CreateTexture: " + String(cString: SDL_GetError()))
            return false
        }
        
        texture = t
        
        weak var weakSelf = self
        eventQueue?.async {
            var event: SDL_Event = SDL_Event()
            event_loop: while true {
                SDL_PollEvent(&event)
                
                switch event.type {
                case SDL_FINGERDOWN.rawValue, SDL_QUIT.rawValue:
                    DispatchQueue.main.async(execute: {
                        
                        guard let ws = weakSelf else {
                            return
                        }
                        
                        ws.player?.cancel()
                        ws.player = nil
                        ws.displayLink?.isPaused = true
                        ws.displayLink?.invalidate()
                        SDL_DestroyTexture(ws.texture)
                        SDL_DestroyRenderer(ws.renderer)
                        SDL_DestroyWindow(ws.window)
                        SDL_Quit()
                        
                        let _ = ws.navigationController?.popViewController(animated: true)
                    })
                    break event_loop
                default:
                    break
                }
            }
        }
        
        return true
    }
}

