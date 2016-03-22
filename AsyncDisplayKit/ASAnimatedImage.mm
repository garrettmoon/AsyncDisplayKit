//
//  ASAnimatedImage.m
//  Pods
//
//  Created by Garrett Moon on 3/18/16.
//
//

#import "ASAnimatedImage.h"

#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/UTCoreTypes.h>

#import "ASThread.h"

static NSString *kASAnimatedImageErrorDomain = @"kASAnimatedImageErrorDomain";

const Float32 kASAnimatedImageDefaultDuration = 0.1;
//http://nullsleep.tumblr.com/post/16524517190/animated-gif-minimum-frame-delay-browser
const Float32 kASAnimatedImageMinimumDuration = 0.02;

static const size_t bitsPerComponent = 8;
static const size_t componentsPerPixel = 4;

typedef void(^ASAnimatedImageDecodedData)(NSData *memoryMappedData, NSError *error);
typedef void(^ASAnimatedImageDecodedPath)(NSString *path, NSError *error);

@interface ASSharedAnimatedImage : NSObject

@property (nonatomic, strong, readwrite) NSString *path;
@property (nonatomic, weak, readwrite) NSData *memoryMappedData;
@property (nonatomic, strong, readwrite) NSArray <ASAnimatedImageDecodedData> *completions;
@property (nonatomic, strong, readwrite) NSArray <ASAnimatedImageCoverImage> *coverImageCompletions;
@property (nonatomic, weak, readwrite) UIImage *coverImage;
@property (nonatomic, strong, readwrite) NSError *error;

@end

@interface ASAnimatedImageManager : NSObject
{
  ASDN::Mutex _lock;
}

+ (instancetype)sharedManager;

@property (nonatomic, strong, readonly) NSString *temporaryDirectory;
@property (nonatomic, strong, readonly) NSMutableDictionary <NSUUID *, ASSharedAnimatedImage *> *animatedImages;
@property (nonatomic, strong, readonly) dispatch_queue_t serialProcessingQueue;

@end

@interface ASAnimatedImage ()
{
  ASDN::Mutex _statusLock;
  ASDN::Mutex _completionLock;
}

//Set on init
@property (nonatomic, strong, readonly) NSUUID *UUID;

@property (nonatomic, strong, readonly) NSData *memoryMappedData;
@property (nonatomic, strong, readonly) UIImage *coverImage;

+ (UIImage *)coverImageWithMemoryMap:(NSData *)memoryMap;

@end

@implementation ASAnimatedImageManager

#if ASAnimatedImageDebug
+ (void)load
{
  if (self == [ASAnimatedImageManager class]) {
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"ASAnimatedImageCache"] error:&error];
  }
}
#endif

+ (instancetype)sharedManager
{
  static dispatch_once_t onceToken;
  static ASAnimatedImageManager *sharedManager;
  dispatch_once(&onceToken, ^{
    sharedManager = [[ASAnimatedImageManager alloc] init];
  });
  return sharedManager;
}

- (instancetype)init
{
  if (self = [super init]) {
    _temporaryDirectory = [[NSTemporaryDirectory() stringByAppendingPathComponent:@"ASAnimatedImageCache"] stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    _animatedImages = [[NSMutableDictionary alloc] init];
    _serialProcessingQueue = dispatch_queue_create("Serial animated image processing queue.", DISPATCH_QUEUE_SERIAL);
    
    __weak ASAnimatedImageManager *weakSelf = self;
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil
                                                       queue:nil
                                                  usingBlock:^(NSNotification * _Nonnull note) {
                                                    [weakSelf cleanupFiles];
                                                  }];
  }
  return self;
}

- (void)cleanupFiles
{
  [[NSFileManager defaultManager] removeItemAtPath:self.temporaryDirectory error:nil];
}

- (void)animatedPathForUUID:(NSUUID *)UUID animatedImageData:(NSData *)animatedImageData coverImageCompletion:(ASAnimatedImageCoverImage)coverImageCompletion completion:(ASAnimatedImageDecodedData)completion
{
  BOOL startProcessing = NO;
  {
    ASDN::MutexLocker l(_lock);
    ASSharedAnimatedImage *shared = self.animatedImages[UUID];
    if (shared == nil) {
      shared = [[ASSharedAnimatedImage alloc] init];
      self.animatedImages[UUID] = shared;
      startProcessing = YES;
    }
    
    if (shared.path) {
      NSData *memoryMappedData = shared.memoryMappedData;
      NSError *error = nil;
      if (memoryMappedData == nil) {
        memoryMappedData = [NSData dataWithContentsOfFile:shared.path options:NSDataReadingMappedAlways error:&error];
        shared.memoryMappedData = memoryMappedData;
      }
      if (completion) {
        completion(memoryMappedData, error);
      }
    } else if (shared.error) {
      if (completion) {
        completion(nil, shared.error);
      }
    } else {
      if (completion) {
        shared.completions = [shared.completions arrayByAddingObject:completion];
      }
    }
    
    if (shared.coverImage) {
      if (coverImageCompletion) {
        coverImageCompletion(shared.coverImage);
      }
    } else if (shared.memoryMappedData) {
      //special case where image is processed, but we don't have a cover image any more.
      UIImage *coverImage = [ASAnimatedImage coverImageWithMemoryMap:shared.memoryMappedData];
      shared.coverImage = coverImage;
      if (coverImageCompletion) {
        coverImageCompletion(coverImage);
      }
    } else {
      if (coverImageCompletion) {
        shared.coverImageCompletions = [shared.coverImageCompletions arrayByAddingObject:coverImageCompletion];
      }
    }
  }
  
  if (startProcessing) {
    dispatch_async(self.serialProcessingQueue, ^{
      [[self class] processAnimatedImage:animatedImageData temporaryDirectory:self.temporaryDirectory UUID:UUID coverImage:^(UIImage *coverImage) {
        NSArray *coverImageCompletions = nil;
        {
          ASDN::MutexLocker l(_lock);
          ASSharedAnimatedImage *shared = self.animatedImages[UUID];
          shared.coverImage = coverImage;
          coverImageCompletions = shared.coverImageCompletions;
          shared.coverImageCompletions = @[];
        }
        
        for (ASAnimatedImageCoverImage coverImageCompletion in coverImageCompletions) {
          coverImageCompletion(coverImage);
        }
      } completion:^(NSString *path, NSError *error) {
        NSArray *completions = nil;
        NSData *memoryMappedData = nil;
        {
          ASDN::MutexLocker l(_lock);
          ASSharedAnimatedImage *shared = self.animatedImages[UUID];
          
          shared.path = path;
          shared.error = error;
          
          if (path && error == nil) {
            memoryMappedData = [NSData dataWithContentsOfFile:shared.path options:NSDataReadingMappedAlways error:&error];
          }
          if (memoryMappedData) {
            shared.memoryMappedData = memoryMappedData;
          }
          completions = shared.completions;
          shared.completions = @[];
        }
        
        for (ASAnimatedImageDecodedData completion in completions) {
          completion(memoryMappedData, error);
        }
      }];
    });
  }
}

+ (void)processAnimatedImage:(NSData *)animatedImageData temporaryDirectory:(NSString *)temporaryDirectory UUID:(NSUUID *)UUID coverImage:(ASAnimatedImageCoverImage)coverImageCompletion completion:(ASAnimatedImageDecodedPath)completion
{
  NSError *error = nil;
  NSFileHandle *fileHandle = [self fileHandle:&error temporaryDirectory:temporaryDirectory UUID:UUID];
  UInt32 width;
  UInt32 height;
  
  if (fileHandle && error == nil) {
    CGImageSourceRef imageSource = CGImageSourceCreateWithData((CFDataRef)animatedImageData,
                                                               (CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceTypeIdentifierHint : (__bridge NSString *)kUTTypeGIF,
                                                                                  (__bridge NSString *)kCGImageSourceShouldCache : (__bridge NSNumber *)kCFBooleanFalse});
    
    if (imageSource) {
      UInt32 frameCount = (UInt32)CGImageSourceGetCount(imageSource);
      NSDictionary *imageProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyProperties(imageSource, nil);
      UInt32 loopCount = (UInt32)[[[imageProperties objectForKey:(__bridge NSString *)kCGImagePropertyGIFDictionary]
                           objectForKey:(__bridge NSString *)kCGImagePropertyGIFLoopCount] unsignedLongValue];
      
      for (NSUInteger frameIdx = 0; frameIdx < frameCount; frameIdx++) {
        @autoreleasepool {
          CGImageRef frameImage = CGImageSourceCreateImageAtIndex(imageSource, frameIdx, (CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceShouldCache : (__bridge NSNumber *)kCFBooleanFalse});
          if (frameImage == nil) {
            error = [NSError errorWithDomain:kASAnimatedImageErrorDomain code:ASAnimatedImageErrorImageFrameError userInfo:nil];
            break;
          }
          
          if (frameIdx == 0) {
            //Get size, write file header get coverImage
            width = (UInt32)CGImageGetWidth(frameImage);
            height = (UInt32)CGImageGetHeight(frameImage);
            [self writeFileHeader:fileHandle width:width height:height loopCount:loopCount frameCount:frameCount];
            coverImageCompletion([UIImage imageWithCGImage:frameImage]);
          }
          
          Float32 duration = [[self class] frameDurationAtIndex:frameIdx source:imageSource];
          NSData *frameData = (__bridge_transfer NSData *)CGDataProviderCopyData(CGImageGetDataProvider(frameImage));
          NSAssert(frameData.length == width * height * componentsPerPixel, @"data should be width * height * 4 bytes");
          [self writeFrameToFile:fileHandle duration:duration frameData:frameData];
          
          CGImageRelease(frameImage);
        }
      }
      
      CFRelease(imageSource);
    }
    
    //close the file handle
    [fileHandle closeFile];
  }
  
  NSString *filePath = nil;
  if (error == nil) {
    filePath = [self filePathWithTemporaryDirectory:temporaryDirectory UUID:UUID];
  }
  
  completion(filePath, error);
}

//http://stackoverflow.com/questions/16964366/delaytime-or-unclampeddelaytime-for-gifs
+ (Float32)frameDurationAtIndex:(NSUInteger)index source:(CGImageSourceRef)source
{
  Float32 frameDuration = kASAnimatedImageDefaultDuration;
  NSDictionary *frameProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(source, index, nil);
  // use unclamped delay time before delay time before default
  NSNumber *unclamedDelayTime = frameProperties[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFUnclampedDelayTime];
  if (unclamedDelayTime) {
    frameDuration = [unclamedDelayTime floatValue];
  } else {
    NSNumber *delayTime = frameProperties[(__bridge NSString *)kCGImagePropertyGIFDictionary][(__bridge NSString *)kCGImagePropertyGIFDelayTime];
    if (delayTime) {
      frameDuration = [delayTime floatValue];
    }
  }
  
  if (frameDuration < kASAnimatedImageMinimumDuration) {
    frameDuration = kASAnimatedImageDefaultDuration;
  }
  
  return frameDuration;
}

+ (NSString *)filePathWithTemporaryDirectory:(NSString *)temporaryDirectory UUID:(NSUUID *)UUID
{
  return [temporaryDirectory stringByAppendingPathComponent:[UUID UUIDString]];
}

+ (NSFileHandle *)fileHandle:(NSError **)error temporaryDirectory:(NSString *)temporaryDirectory UUID:(NSUUID *)UUID
{
  NSString *dirPath = temporaryDirectory;
  NSString *filePath = [self filePathWithTemporaryDirectory:temporaryDirectory UUID:UUID];
  NSError *outError = nil;
  NSFileHandle *fileHandle = nil;
  
  if ([[NSFileManager defaultManager] fileExistsAtPath:dirPath] == NO) {
    [[NSFileManager defaultManager] createDirectoryAtPath:dirPath withIntermediateDirectories:YES attributes:nil error:&outError];
  }
  
  if (outError == nil) {
    BOOL success = [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
    if (success == NO) {
      outError = [NSError errorWithDomain:kASAnimatedImageErrorDomain code:ASAnimatedImageErrorFileCreationError userInfo:nil];
    }
  }
  
  if (outError == nil) {
    fileHandle = [NSFileHandle fileHandleForWritingAtPath:filePath];
    if (fileHandle == nil) {
      outError = [NSError errorWithDomain:kASAnimatedImageErrorDomain code:ASAnimatedImageErrorFileHandleError userInfo:nil];
    }
  }
  
  if (error) {
    *error = outError;
  }
  
  return fileHandle;
}

/**
 ASAnimatedImage file
 
 Header:
 [version] 2 bytes
 [width] 4 bytes
 [height] 4 bytes
 [loop count] 4 bytes
 [frame count] 4 bytes
 [frame(s)]
 
 Each frame:
 [duration] 4 bytes
 [frame data] width * height * 4 bytes
 
 */

static const NSUInteger kHeaderLength = 2 + 4 + 4 + 4 + 4;

+ (void)writeFileHeader:(NSFileHandle *)fileHandle width:(UInt32)width height:(UInt32)height loopCount:(UInt32)loopCount frameCount:(UInt32)frameCount
{
  UInt16 version = 1;
  [fileHandle writeData:[NSData dataWithBytes:&version length:sizeof(version)]];
  [fileHandle writeData:[NSData dataWithBytes:&width length:sizeof(width)]];
  [fileHandle writeData:[NSData dataWithBytes:&height length:sizeof(height)]];
  [fileHandle writeData:[NSData dataWithBytes:&loopCount length:sizeof(loopCount)]];
  [fileHandle writeData:[NSData dataWithBytes:&frameCount length:sizeof(frameCount)]];
}

+ (void)writeFrameToFile:(NSFileHandle *)fileHandle duration:(Float32)duration frameData:(NSData *)frameData
{
  NSData *durationData = [NSData dataWithBytes:&duration length:sizeof(duration)];
  [fileHandle writeData:durationData];
  [fileHandle writeData:frameData];
}

@end

@implementation ASAnimatedImage

@synthesize coverImage = _coverImage;

- (instancetype)init
{
  return [self initWithAnimatedImageData:nil UUID:nil];
}

- (instancetype)initWithAnimatedImageData:(NSData *)animatedImageData UUID:(NSUUID *)UUID
{
  if (self = [super init]) {
    ASDisplayNodeAssertNotNil(animatedImageData, @"animatedImageData must not be nil.");
    _status = ASAnimatedImageStatusUnprocessed;
    if (UUID == nil) {
      _UUID = [[NSUUID alloc] init];
    } else {
      _UUID = UUID;
    }
    _status = ASAnimatedImageStatusProcessing;
    
    [[ASAnimatedImageManager sharedManager] animatedPathForUUID:_UUID animatedImageData:animatedImageData coverImageCompletion:^(UIImage *coverImage) {
      {
        ASDN::MutexLocker l(_statusLock);
        if (_status == ASAnimatedImageStatusProcessing) {
          _status = ASAnimatedImageStatusCoverImageCompleted;
        }
        _coverImage = coverImage;
      }
      {
        ASDN::MutexLocker l(_completionLock);
        _coverImageCompletion(coverImage);
      }
    } completion:^(NSData *memoryMappedData, NSError *error) {
      BOOL success = NO;
      {
        ASDN::MutexLocker l(_statusLock);
        if (memoryMappedData && error == nil) {
          _status = ASAnimatedImageStatusProcessed;
          _memoryMappedData = memoryMappedData;
          
          [self pullLocalDataFromMemoryMap:memoryMappedData];
          
          success = YES;
        } else {
          _status = ASAnimatedImageStatusError;
#if ASAnimatedImageDebug
          NSLog(@"animated image error: %@", error);
#endif
        }
      }
      
      if (success) {
        ASDN::MutexLocker l(_completionLock);
        _animatedImageReady();
      }
    }];
  }
  return self;
}

- (instancetype)initWithAnimatedImageData:(NSData *)animatedImageData
{
  return [self initWithAnimatedImageData:animatedImageData UUID:nil];
}

- (void)setCoverImageCompletion:(ASAnimatedImageCoverImage)coverImageCompletion
{
  ASDN::MutexLocker l(_completionLock);
  _coverImageCompletion = coverImageCompletion;
}

- (void)setAnimatedImageReady:(dispatch_block_t)animatedImageReady
{
  ASDN::MutexLocker l(_completionLock);
  _animatedImageReady = animatedImageReady;
}

+ (UIImage *)coverImageWithMemoryMap:(NSData *)memoryMap
{
  return [UIImage imageWithCGImage:[self imageAtIndex:0 inMemoryMap:memoryMap duration:nil]];
}

void releaseData(void *data, const void *imageData, size_t size);

void releaseData(void *data, const void *imageData, size_t size)
{
  CFRelease(data);
}

+ (CGImageRef)imageAtIndex:(NSUInteger)index inMemoryMap:(NSData *)memoryMap duration:(Float32 *)duration
{
  Float32 outDuration;
  
  UInt32 width = [self widthFromMemoryMap:memoryMap];
  UInt32 height = [self heightFromMemoryMap:memoryMap];
  
  size_t imageLength = width * height * componentsPerPixel;
  
  NSUInteger offset = kHeaderLength + (index * (imageLength + sizeof(outDuration)));
  
  [memoryMap getBytes:&outDuration range:NSMakeRange(offset, sizeof(outDuration))];
  
  BytePtr imageData = (BytePtr)[memoryMap bytes];
  imageData += offset + sizeof(outDuration);
  
  ASDisplayNodeAssert(offset + sizeof(outDuration) + imageLength <= memoryMap.length, @"Requesting frame beyond data bounds");
  
  //retain the memory map, it will be released when releaseData is called
  CFRetain((CFDataRef)memoryMap);
  CGDataProviderRef dataProvider = CGDataProviderCreateWithData((void *)memoryMap, imageData, width * height * componentsPerPixel, releaseData);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef imageRef = CGImageCreate(width,
                                      height,
                                      bitsPerComponent,
                                      bitsPerComponent * componentsPerPixel,
                                      componentsPerPixel * width,
                                      colorSpace,
                                      kCGBitmapByteOrderDefault | kCGImageAlphaNoneSkipLast,
                                      dataProvider,
                                      NULL,
                                      NO,
                                      kCGRenderingIntentDefault);
  CFAutorelease(imageRef);
  
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(dataProvider);
  
  if (duration) {
    *duration = outDuration;
  }
  
  return imageRef;
}

+ (UInt32)widthFromMemoryMap:(NSData *)memoryMap
{
  UInt32 width;
  [memoryMap getBytes:&width range:NSMakeRange(2, sizeof(width))];
  return width;
}

+ (UInt32)heightFromMemoryMap:(NSData *)memoryMap
{
  UInt32 height;
  [memoryMap getBytes:&height range:NSMakeRange(6, sizeof(height))];
  return height;
}

+ (UInt32)loopCountFromMemoryMap:(NSData *)memoryMap
{
  UInt32 loopCount;
  [memoryMap getBytes:&loopCount range:NSMakeRange(10, sizeof(loopCount))];
  return loopCount;
}

+ (UInt32)frameCountFromMemoryMap:(NSData *)memoryMap
{
  UInt32 frameCount;
  [memoryMap getBytes:&frameCount range:NSMakeRange(14, sizeof(frameCount))];
  return frameCount;
}

+ (NSArray *)durationsFromMemoryMap:(NSData *)memoryMap frameCount:(UInt32)frameCount frameSize:(NSUInteger)frameSize totalDuration:(CFTimeInterval *)totalDuration
{
  *totalDuration = 0;
  NSMutableArray *durations = [[NSMutableArray alloc] initWithCapacity:frameCount];
  for (NSUInteger frameIdx = 0; frameIdx < frameCount; frameIdx++) {
    Float32 duration;
    [memoryMap getBytes:&duration range:NSMakeRange(kHeaderLength + (frameSize * frameIdx), sizeof(duration))];
    [durations addObject:@(duration)];
    *totalDuration += duration;
  }
  return durations;
}

- (void)pullLocalDataFromMemoryMap:(NSData *)memoryMap
{
  _width = [[self class] widthFromMemoryMap:memoryMap];
  _height = [[self class] heightFromMemoryMap:memoryMap];
  _loopCount = [[self class] loopCountFromMemoryMap:memoryMap];
  _frameCount = [[self class] frameCountFromMemoryMap:memoryMap];
  _durations = [[self class] durationsFromMemoryMap:memoryMap frameCount:(UInt32)_frameCount frameSize:(_width * _height * componentsPerPixel) + 4 totalDuration:&_totalDuration];
}

- (ASAnimatedImageStatus)status
{
  ASDN::MutexLocker l(_statusLock);
  return _status;
}

- (CGImageRef)imageAtIndex:(NSUInteger)index
{
  return [[self class] imageAtIndex:index inMemoryMap:self.memoryMappedData duration:nil];
}

@end

@implementation ASSharedAnimatedImage

- (instancetype)init
{
  if (self = [super init]) {
    _completions = @[];
    _coverImageCompletions = @[];
  }
  return self;
}

@end
