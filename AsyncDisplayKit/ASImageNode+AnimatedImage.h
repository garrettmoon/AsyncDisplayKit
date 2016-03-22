//
//  ASImageNode+AnimatedImage.h
//  Pods
//
//  Created by Garrett Moon on 3/22/16.
//
//

#import "ASImageNode.h"

#import "ASThread.h"

@interface ASImageNode ()
{
  ASDN::RecursiveMutex _animatedImageLock;
  ASDN::Mutex _displayLinkLock;
  ASAnimatedImage *_animatedImage;
  CADisplayLink *_displayLink;
  
  //accessed on main thread only
  CFTimeInterval _playHead;
  NSUInteger _playedLoops;
}

@end

@interface ASImageNode (AnimatedImage)

- (void)coverImageCompleted:(UIImage *)coverImage;
- (void)animatedImageReady;

@end
