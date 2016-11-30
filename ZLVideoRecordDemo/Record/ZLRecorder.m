//
//  ZLRecorder.m
//  ZLVideoRecordDemo
//
//  Created by liangzhimy on 16/11/24.
//  Copyright © 2016年 liangzhimy. All rights reserved.
//

#import "ZLRecorder.h"
#import "ZLRecorderCore.h"

#import <UIKit/UIKit.h>
#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMAudioClock.h>
#import <AssetsLibrary/AssetsLibrary.h>

#define RETAINED_BUFFER_COUNT 6; 

static NSString * const __ZLRecordTempFileName = @"movie.mov";

typedef NS_ENUM(NSUInteger, ZLRecordingStatus) {
    ZLRecordingStatsIdle = 0,
    ZLRecordingStatsStartingRecording,
    ZLRecordingStatusRecording,
    ZLRecordingStatusStopingRecord
};

@interface ZLRecorder () <AVCaptureVideoDataOutputSampleBufferDelegate> {
    AVCaptureSession *_captureSession;
    AVCaptureDevice *_videoDevice;
    AVCaptureConnection *_audioConnection;
    AVCaptureConnection *_videoConnection;
    AVCaptureVideoOrientation _videoBufferOrientation;
    
    BOOL _running;
    BOOL _startCaptureSessionOnEnteringForeground;
    id _applicationWillEnterForegroundNotificationObserver;
    
    NSMutableArray *_previousSecondTimestamps;
    
    NSDictionary *_videoCompressionSetting;
    NSDictionary *_audioCompressionSetting;
    
    dispatch_queue_t _sessionQueue;
    
    dispatch_queue_t _videoDataOutputQueue;
    
    ZLRecorderCore *_recorder; 
    NSURL *_recordingURL;
    ZLRecordingStatus _recordingStatus; 
    
    UIBackgroundTaskIdentifier _recordRunningTask; 
    
    __weak id<ZLRecordCaptureDelegate> _delegate; 
    dispatch_queue_t _delegateCallbackQueue;
}

@property (atomic, readwrite) float videoFrameRate;
@property (atomic, readwrite) CMVideoDimensions videoDimensions; 

@property (strong, nonatomic) __attribute__((NSObject)) CVPixelBufferRef currentPreviewPixelBuffer;
@property (strong, nonatomic) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property (strong, nonatomic) __attribute__((NSObject)) CMFormatDescriptionRef outputAudioFormatDescription;

@end

@implementation ZLRecorder

- (instancetype)initWithDelegate:(id<ZLRecordCaptureDelegate>)delegate callbackQueue:(dispatch_queue_t)queue { 
    NSParameterAssert(delegate != nil);
    NSParameterAssert(queue != nil);
    self = [super init];
    if (self) {
        _previousSecondTimestamps = [[NSMutableArray alloc] init];
        _recordingOrientation = AVCaptureVideoOrientationPortrait;
        
        _recordingURL = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), __ZLRecordTempFileName]]];
        
        _sessionQueue = dispatch_queue_create("com.zl.record.session", DISPATCH_QUEUE_SERIAL);
        
        _videoDataOutputQueue = dispatch_queue_create("com.zl.record.video", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_videoDataOutputQueue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
        
        _recorder = [[ZLRecorderCore alloc] init];
        
        _recordRunningTask = UIBackgroundTaskInvalid;
        _delegate = delegate;
        _delegateCallbackQueue = queue;
    }
    return self;
}

- (void)dealloc {
//    [self teardownCaptureSession];
}

#pragma mark - capture session

- (void)startRunning {
    dispatch_sync(_sessionQueue, ^{
        [self setupCaptureSession];
        
        if (_captureSession) {
            [_captureSession startRunning];
        }
        
        _running = YES; 
    });
}

- (void)stopRunning {
    dispatch_sync(_sessionQueue, ^{
        _running = NO;
        [self stopRecording];
        
        [_captureSession stopRunning];
        
        [self captureSessionDidStopRunning]; 
        
        [self teardownCaptureSession]; 
    }); 
} 

- (void)setupCaptureSession {
    if (_captureSession) {
        return; 
    }
    
    _captureSession = [[AVCaptureSession alloc] init];
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(captureSessionNotification:) name:nil object:_captureSession];
    
    _applicationWillEnterForegroundNotificationObserver = [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillEnterForegroundNotification object:[UIApplication sharedApplication] queue:nil usingBlock:^(NSNotification * _Nonnull note) {
        [self applicationWillEnterForeground]; 
    }];
    
    /* Audio */
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:nil];
    if ([_captureSession canAddInput:audioIn]) {
        [_captureSession addInput:audioIn]; 
    }
    
    AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
    dispatch_queue_t audioCaptureQueue = dispatch_queue_create("com.zl.record.audio", DISPATCH_QUEUE_SERIAL);
    [audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
    
    if ([_captureSession canAddOutput:audioOut]) {
        [_captureSession addOutput:audioOut]; 
    }
    
    _audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
    
    /* Video */
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *videoDeviceError = nil;
    AVCaptureDeviceInput *videoInput = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:&videoDeviceError];
    if ([_captureSession canAddInput:videoInput]) {
        [_captureSession addInput:videoInput];
        _videoDevice = videoDevice;
    } else {
        [self handleNonRecoverableCaptureSessionRuntimeError:videoDeviceError];
        return;
    }
    
    AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
    [videoOut setSampleBufferDelegate:self queue:_videoDataOutputQueue];
    videoOut.alwaysDiscardsLateVideoFrames = NO;
    
    if ([_captureSession canAddOutput:videoOut]) {
        [_captureSession addOutput:videoOut];
    }
    _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
    
    int frameRate;
    NSString *sessionPreset = AVCaptureSessionPresetHigh;
    CMTime frameDuration = kCMTimeInvalid;
    if ([NSProcessInfo processInfo].processorCount == 1) {
        if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480]) {
            sessionPreset = AVCaptureSessionPreset640x480;
        }
        frameRate = 15;
    } else {
        if ([_captureSession canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            sessionPreset = AVCaptureSessionPreset1280x720;
        }
        frameRate = 30;
    }
    
    _captureSession.sessionPreset = sessionPreset;
    
    frameDuration = CMTimeMake(1, frameRate);
    
    NSError *error = nil;
    if ([videoDevice lockForConfiguration:&error]) {
        videoDevice.activeVideoMaxFrameDuration = frameDuration;
        videoDevice.activeVideoMinFrameDuration = frameDuration;
        [videoDevice unlockForConfiguration];
    } else {
        NSLog(@"videoDevice lockForConfiguration return error %@", error); 
    }
    
    _audioCompressionSetting = [[audioOut recommendedAudioSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
    
    _videoCompressionSetting = [[videoOut recommendedVideoSettingsForAssetWriterWithOutputFileType:AVFileTypeQuickTimeMovie] copy];
    
    _videoBufferOrientation = _videoConnection.videoOrientation;
}

- (void)teardownCaptureSession {
    if (_captureSession) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:nil object:_captureSession];
        [[NSNotificationCenter defaultCenter] removeObserver:_applicationWillEnterForegroundNotificationObserver];
        _applicationWillEnterForegroundNotificationObserver = nil;
        
        _captureSession = nil;
        _videoCompressionSetting = nil;
        _audioCompressionSetting = nil;
    } 
}

- (void)captureSessionNotification:(NSNotification *)notification {
    dispatch_async(_sessionQueue, ^{
        if ([notification.name isEqualToString:AVCaptureSessionWasInterruptedNotification]) {
            [self captureSessionDidStopRunning]; 
        } else if ([notification.name isEqualToString:AVCaptureSessionInterruptionEndedNotification]) {
            NSLog(@"session interruption ended"); 
        } else if ([notification.name isEqualToString:AVCaptureSessionRuntimeErrorNotification]) {
            [self captureSessionDidStopRunning];
            
            NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
            if (error.code == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableInBackground) {
                NSLog(@"device not available in background");
                
                if (_running) {
                    _startCaptureSessionOnEnteringForeground = YES;
                } 
            } else if (error.code == AVErrorMediaServicesWereReset) {
                NSLog(@"media service were reset");
                [self handleNonRecoverableCaptureSessionRuntimeError:error];
            } else {
                [self handleNonRecoverableCaptureSessionRuntimeError:error]; 
            } 
        } else if ([notification.name isEqualToString:AVCaptureSessionDidStartRunningNotification]) {
            NSLog(@"session started running"); 
        }  else if ([notification.name isEqualToString:AVCaptureSessionDidStopRunningNotification]) {
            NSLog(@"session stopped running"); 
        }
    }); 
}

- (void)handleRecoverableCaptureSessionRuntimeError:(NSError *)error {
    if (_running) {
        [_captureSession startRunning]; 
    } 
}

- (void)handleNonRecoverableCaptureSessionRuntimeError:(NSError *)error {
    _running = NO;
    [self teardownCaptureSession];
    
    [self invokeDelegateCallbackAsync:^{
        [_delegate recordCapture:self didStopRunningWithError:error];
    }];
}

- (void)captureSessionDidStopRunning {
    [self stopRecording];
    [self teardownVideoRecorder];
}

- (void)applicationWillEnterForeground {
    dispatch_sync(_sessionQueue, ^{
        if (_startCaptureSessionOnEnteringForeground) {
            _startCaptureSessionOnEnteringForeground = NO;
            if (_running) {
                [_captureSession startRunning];
            } 
        }
    }); 
}

#pragma mark - Capture Pipeline 

- (void)setupVideoRecordWithInputFormatDescription:(CMFormatDescriptionRef)inputFormatDescription {
    
    [self videoRecordWillStartRunning];
    
    self.videoDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription);
//    [_recorder prepareForInputWithFormatDescription:inputFormatDescription outputRetainedBufferCountHint:RETAINED_BUFFER_COUNT];
    
    if (!_recorder.operatesInPlace && [_recorder respondsToSelector:@selector(outputFormatDescription)]) {
        self.outputVideoFormatDescription = _recorder.outputF
    } else {
        
    }
}

- (void)videoRecordWillStartRunning {
    _recordRunningTask = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
        NSLog(@"video capture pipeline background task expired");
    }]; 
}

- (void)videoRecordDidFinishRunning {
    [[UIApplication sharedApplication] endBackgroundTask:_recordRunningTask];
    _recordRunningTask = UIBackgroundTaskInvalid;
} 

- (void)teardownVideoRecorder {
    NSLog(@"- [%@, %@] called ", [self class], NSStringFromSelector(_cmd));
    dispatch_sync(_videoDataOutputQueue, ^{
        if (!self.outputVideoFormatDescription) {
            return;
        }
        
        self.outputVideoFormatDescription = NULL;
//        [_renderer reset];
        self.currentPreviewPixelBuffer = NULL;
        
        [self videoRecorderDidFinishRunning];
    });
}

- (void)videoRecorderDidFinishRunning {
    [[UIApplication sharedApplication] endBackgroundTask:_recordRunningTask];
    _recordRunningTask = UIBackgroundTaskInvalid;
}

- (void)invokeDelegateCallbackAsync:(void (^)())callback {
    
}



#pragma mark - ZLRecordCaptureDelegate

- (void)recordCapture:(ZLRecorder *)captureRecord didStopRunningWithError:(NSError *)error {
}

- (void)recordCapture:(ZLRecorder *)captureRecord previewPixelBufferReadyForDisplay:(CVPixelBufferRef)previewPixelBuffer {
} 

- (void)recordCapture:(ZLRecorder *)captureRecord recordingDidStart:(id)placeHolder {
}

- (void)recordCapture:(ZLRecorder *)captureRecord recordingDidFailWithError:(NSError *)error {
}

- (void)recordCapture:(ZLRecorder *)captureRecord willStop:(id)placeHolder {
}

- (void)recordCapture:(ZLRecorder *)captureRecord didStop:(id)placeHolder {
}

@end
