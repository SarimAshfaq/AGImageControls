//
//  AGCameraService.swift
//  AGPosterSnap
//
//  Created by Michael Liptuga on 13.07.17.
//  Copyright © 2017 Agilie. All rights reserved.
//

import Foundation

import AVFoundation
import PhotosUI

protocol AGPhoneCameraDelegate: class {
    func cameraNotAvailable(_ phoneCamera: AGPhoneCamera)
    func cameraDidStart(_ phoneCamera: AGPhoneCamera)
    func camera(_ phoneCamera: AGPhoneCamera, didChangeInput input: AVCaptureDeviceInput)
}

class AGPhoneCamera {
    weak var delegate: AGPhoneCameraDelegate?
    
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "AGImagePicker.Camera.SessionQueue")
    
    var backCamera            : AVCaptureDeviceInput?
    var frontCamera           : AVCaptureDeviceInput?
    var stillImageOutput      : AVCaptureStillImageOutput?
    var startOnFrontCamera    : Bool = false
    
    deinit {
        stop()
    }
    
    // MARK: - Setup
    func setup(_ startOnFrontCamera: Bool = false) {
        self.startOnFrontCamera = startOnFrontCamera
        checkPermission()
    }
    
    func setupDevices() {
        // Input
        AVCaptureDevice
            .devices().flatMap {
                return $0 as? AVCaptureDevice
            }.filter {
                return $0.hasMediaType(AVMediaTypeVideo)
            }.forEach {
                switch $0.position {
                case .front:
                    self.frontCamera = try? AVCaptureDeviceInput(device: $0)
                case .back:
                    self.backCamera = try? AVCaptureDeviceInput(device: $0)
                default:
                    break
                }
        }
        
        // Output
        stillImageOutput = AVCaptureStillImageOutput()
        stillImageOutput?.outputSettings = [AVVideoCodecKey: AVVideoCodecJPEG]
    }
    
    func addInput(_ input: AVCaptureDeviceInput) {
        configurePreset(input)
        
        if session.canAddInput(input) {
            session.addInput(input)
            
            DispatchQueue.main.async {
                self.delegate?.camera(self, didChangeInput: input)
            }
        }
    }
    
    // MARK: - Permission
    
    func checkPermission() {
        let status = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)
        
        switch status {
        case .authorized:
            start()
        case .notDetermined:
            requestPermission()
        default:
            delegate?.cameraNotAvailable(self)
        }
    }
    
    func requestPermission() {
        AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.start()
                } else {
                    self.delegate?.cameraNotAvailable(self)
                }
            }
        }
    }
    
    // MARK: - Session
    
    var currentInput: AVCaptureDeviceInput? {
        return session.inputs.first as? AVCaptureDeviceInput
    }
    
    fileprivate func start() {
        // Devices
        setupDevices()
        
        guard let input = (self.startOnFrontCamera) ? frontCamera ?? backCamera : backCamera, let output = stillImageOutput else { return }
        
        addInput(input)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        }
        
        queue.async {
            self.session.startRunning()
            
            DispatchQueue.main.async {
                self.delegate?.cameraDidStart(self)
            }
        }
    }
    
    func stop() {
        self.session.stopRunning()
    }
    
    func switchCamera(_ completion: (() -> Void)? = nil) {
        guard let currentInput = currentInput
            else {
                completion?()
                return
        }
        
        queue.async {
            guard let input = (currentInput == self.backCamera) ? self.frontCamera : self.backCamera
                else {
                    DispatchQueue.main.async {
                        completion?()
                    }
                    return
            }
            
            self.configure {
                self.session.removeInput(currentInput)
                self.addInput(input)
            }
            
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    func takePhoto(_ previewLayer: AVCaptureVideoPreviewLayer, location: CLLocation?, completion: (() -> Void)? = nil) {
        guard let connection = stillImageOutput?.connection(withMediaType: AVMediaTypeVideo) else { return }
        
        connection.videoOrientation = AGCameraHelper.videoOrientation()
        
        queue.async {
            self.stillImageOutput?.captureStillImageAsynchronously(from: connection) {
                buffer, error in
                
                guard let buffer = buffer, error == nil && CMSampleBufferIsValid(buffer),
                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(buffer),
                    let image = UIImage(data: imageData)
                    else {
                        DispatchQueue.main.async {
                            completion?()
                        }
                        return
                }
                
                self.savePhoto(image, location: location, completion: completion)
            }
        }
    }
    
    func savePhoto(_ image: UIImage, location: CLLocation?, completion: (() -> Void)? = nil) {
        PHPhotoLibrary.shared().performChanges({
            let request = PHAssetChangeRequest.creationRequestForAsset(from: image)
            request.creationDate = Date()
            request.location = location
        }, completionHandler: { _ in
            DispatchQueue.main.async {
                completion?()
            }
        })
    }
    
    func flash(_ mode: AVCaptureFlashMode) {
        guard let device = currentInput?.device, device.isFlashModeSupported(mode) else { return }
        
        queue.async {
            self.lock {
                device.flashMode = mode
            }
        }
    }
    
    func focus(_ point: CGPoint) {
        guard let device = currentInput?.device, device.isFocusModeSupported(AVCaptureFocusMode.locked) else { return }
        queue.async {
            self.lock {
                device.focusPointOfInterest = point
            }
        }
    }
    
    // MARK: - Lock
    func lock(_ block: () -> Void) {
        if let device = currentInput?.device, (try? device.lockForConfiguration()) != nil {
            block()
            device.unlockForConfiguration()
        }
    }
    
    // MARK: - Configure
    func configure(_ block: () -> Void) {
        session.beginConfiguration()
        block()
        session.commitConfiguration()
    }
    
    // MARK: - Preset
    func configurePreset(_ input: AVCaptureDeviceInput) {
        for asset in preferredPresets() {
            if input.device.supportsAVCaptureSessionPreset(asset) && self.session.canSetSessionPreset(asset) {
                self.session.sessionPreset = asset
                return
            }
        }
    }
    
    func preferredPresets() -> [String] {
        return [
            AVCaptureSessionPresetHigh,
            AVCaptureSessionPresetMedium,
            AVCaptureSessionPresetLow
        ]
    }
}