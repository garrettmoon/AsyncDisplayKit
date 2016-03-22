//
//  ASAnimatedImage.h
//  Pods
//
//  Created by Garrett Moon on 3/18/16.
//
//

#import <Foundation/Foundation.h>

#define ASAnimatedImageDebug  1

typedef NS_ENUM(NSUInteger, ASAnimatedImageError) {
  ASAnimatedImageErrorNoError = 0,
  ASAnimatedImageErrorFileCreationError,
  ASAnimatedImageErrorFileHandleError,
  ASAnimatedImageErrorImageFrameError,
};

typedef NS_ENUM(NSUInteger, ASAnimatedImageStatus) {
  ASAnimatedImageStatusUnprocessed = 0,
  ASAnimatedImageStatusProcessing,
  ASAnimatedImageStatusCoverImageCompleted,
  ASAnimatedImageStatusProcessed,
  ASAnimatedImageStatusCanceled,
  ASAnimatedImageStatusError,
};

extern const Float32 kASAnimatedImageDefaultDuration;
//http://nullsleep.tumblr.com/post/16524517190/animated-gif-minimum-frame-delay-browser
extern const Float32 kASAnimatedImageMinimumDuration;

typedef void(^ASAnimatedImageCoverImage)(UIImage *coverImage);

@interface ASAnimatedImage : NSObject

- (instancetype)initWithAnimatedImageData:(NSData *)animatedImageData UUID:(NSUUID *)UUID NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithAnimatedImageData:(NSData *)animatedImageData;

@property (nonatomic, strong, readwrite) ASAnimatedImageCoverImage coverImageCompletion;
@property (nonatomic, strong, readwrite) dispatch_block_t animatedImageReady;

@property (nonatomic, assign, readwrite) ASAnimatedImageStatus status;

//Access to any properties or methods below this line before status == ASAnimatedImageStatusProcessed is undefined.
@property (nonatomic, readonly) NSArray <NSNumber *> *durations;
@property (nonatomic, readonly) CFTimeInterval totalDuration;
@property (nonatomic, readonly) size_t loopCount;
@property (nonatomic, readonly) size_t frameCount;
@property (nonatomic, readonly) size_t width;
@property (nonatomic, readonly) size_t height;

- (CGImageRef)imageAtIndex:(NSUInteger)index;

@end
