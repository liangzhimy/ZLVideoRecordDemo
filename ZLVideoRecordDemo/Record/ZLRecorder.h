//
//  ZLRecorder.h
//  ZLVideoRecordDemo
//
//  Created by liangzhimy on 16/11/24.
//  Copyright © 2016年 liangzhimy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@protocol ZLRecordCaptureDelegate;

@interface ZLRecorder : NSObject

@property (atomic) BOOL renderingEnable;
@property (atomic) AVCaptureVideoOrientation recordingOrientation;

@property (atomic, readonly) float videoFrameRate;
@property (atomic, readonly) CMVideoDimensions videoDimensions;

- (void)startRunning;
- (void)stopRunning;

- (void)startRecording;
- (void)stopRecording;

- (instancetype)initWithDelegate:(id<ZLRecordCaptureDelegate>)delegate callbackQueue:(dispatch_queue_t)queue;

@end

@protocol ZLRenderer <NSObject>

@end

@protocol ZLRecordCaptureDelegate <NSObject>

@required
- (void)recordCapture:(ZLRecorder *)captureRecord didStopRunningWithError:(NSError *)error;
- (void)recordCapture:(ZLRecorder *)captureRecord previewPixelBufferReadyForDisplay:(CVPixelBufferRef)previewPixelBuffer;

- (void)recordCapture:(ZLRecorder *)captureRecord recordingDidStart:(id)placeHolder;
- (void)recordCapture:(ZLRecorder *)captureRecord recordingDidFailWithError:(NSError *)error;

- (void)recordCapture:(ZLRecorder *)captureRecord willStop:(id)placeHolder;
- (void)recordCapture:(ZLRecorder *)captureRecord didStop:(id)placeHolder;

@end
