//
//  CyBlurView.m
//  CyBlurView
//
//  Created by Skyler Whittlesey on 4/29/15.
//  Copyright (c) 2015 Skyler Whittlesey. All rights reserved.
//

#import "CyBlurView.h"

@import Accelerate;

#pragma mark - Blur UIImageView Category

@interface UIImage (CyBlurView)

- (UIImage *)blurredImageWithRadius:(CGFloat)radius ratio:(CGFloat)ratio iterations:(NSUInteger)iterations tintColor:(UIColor *)tintColor;

@end


@implementation UIImage (CyBlurView)

// Borrowed from FXBlurView, slightly modified to accept a ratio
- (UIImage *)blurredImageWithRadius:(CGFloat)radius ratio:(CGFloat)ratio iterations:(NSUInteger)iterations tintColor:(UIColor *)tintColor
{
    if (floorf(self.size.width) * floorf(self.size.height) <= 0.0) {
        return self;
    }
    
    uint32_t boxSize = (uint32_t)(radius * self.scale * ratio);
    if (boxSize % 2 == 0) {
        boxSize ++;
    }
    
    //create image buffers
    CGImageRef imageRef = self.CGImage;
    vImage_Buffer buffer1, buffer2;
    buffer1.width = buffer2.width = CGImageGetWidth(imageRef);
    buffer1.height = buffer2.height = CGImageGetHeight(imageRef);
    buffer1.rowBytes = buffer2.rowBytes = CGImageGetBytesPerRow(imageRef);
    size_t bytes = buffer1.rowBytes * buffer1.height;
    buffer1.data = malloc(bytes);
    buffer2.data = malloc(bytes);
    
    //create temp buffer
    void *tempBuffer = malloc((size_t)vImageBoxConvolve_ARGB8888(&buffer1, &buffer2, NULL, 0, 0, boxSize, boxSize,
                                                                 NULL, kvImageEdgeExtend + kvImageGetTempBufferSize));
    
    //copy image data
    CFDataRef dataSource = CGDataProviderCopyData(CGImageGetDataProvider(imageRef));
    memcpy(buffer1.data, CFDataGetBytePtr(dataSource), bytes);
    CFRelease(dataSource);
    
    for (NSUInteger i = 0; i < iterations; i++)
    {
        //perform blur
        vImageBoxConvolve_ARGB8888(&buffer1, &buffer2, tempBuffer, 0, 0, boxSize, boxSize, NULL, kvImageEdgeExtend);
        
        //swap buffers
        void *temp = buffer1.data;
        buffer1.data = buffer2.data;
        buffer2.data = temp;
    }
    
    //free buffers
    free(buffer2.data);
    free(tempBuffer);
    
    //create image context from buffer
    CGContextRef ctx = CGBitmapContextCreate(buffer1.data, buffer1.width, buffer1.height,
                                             8, buffer1.rowBytes, CGImageGetColorSpace(imageRef),
                                             CGImageGetBitmapInfo(imageRef));
    
    //apply tint
    if (tintColor && CGColorGetAlpha(tintColor.CGColor) > 0.0f)
    {
        CGContextSetFillColorWithColor(ctx, [tintColor colorWithAlphaComponent:0.25].CGColor);
        CGContextSetBlendMode(ctx, kCGBlendModePlusLighter);
        CGContextFillRect(ctx, CGRectMake(0, 0, buffer1.width, buffer1.height));
    }
    
    //create image from context
    imageRef = CGBitmapContextCreateImage(ctx);
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:self.scale orientation:self.imageOrientation];
    CGImageRelease(imageRef);
    CGContextRelease(ctx);
    free(buffer1.data);
    
    return image;
}

@end


#pragma mark - BlurLayer

@interface BlurLayer : CALayer

@property (nonatomic, assign) CGFloat blurRadius;

@end

@implementation BlurLayer

@dynamic blurRadius;

#pragma mark Override

+ (BOOL)needsDisplayForKey:(NSString *)key
{
    if ([key isEqualToString:@"blurRadius"]) {
        return YES;
    }
    return [super needsDisplayForKey:key];
}

@end

#pragma mark - CyBlurView

@interface CyBlurView ()

@property (nonatomic, strong) UIImage *staticImage;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) SEL displayLinkSelector;

@property (nonatomic, strong) NSNumber *fromBlurRadius;
@property (nonatomic, strong) BlurLayer *blurLayer;
@property (nonatomic, strong) BlurLayer *blurPresentationLayer;

@end

@implementation CyBlurView

#pragma mark Init

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = false;
        
        _blurRatio = 1;
        _fullScreenCapture = NO;
        _iterations = 3;
        _dynamicMode = DynamicModeTracking;
        _tintColor = [UIColor clearColor];
        _displayLinkSelector = NSSelectorFromString(@"displayDidRefresh:");
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder
{
    self = [super initWithCoder:aDecoder];
    if (self) {
        self.userInteractionEnabled = false;
        
        _blurRatio = 1;
        _fullScreenCapture = NO;
        _iterations = 3;
        _dynamicMode = DynamicModeTracking;
        _tintColor = [UIColor clearColor];
        _displayLinkSelector = NSSelectorFromString(@"displayDidRefresh:");
    }
    return self;
}

#pragma mark Getter / Setter

- (BlurLayer *)blurLayer
{
    return (BlurLayer *)self.layer;
}

- (BlurLayer *)blurPresentationLayer
{
    if ([(BlurLayer *)self.blurLayer presentationLayer]) {
        return [(BlurLayer *)self.blurLayer presentationLayer];
    }
    return self.blurLayer;
}

- (void)setBlurRadius:(CGFloat)blurRadius
{
    self.blurLayer.blurRadius = blurRadius;
}

- (CGFloat)blurRadius
{
    return self.blurLayer.blurRadius;
}

- (void)setDynamicMode:(DynamicMode)dynamicMode
{
    DynamicMode oldMode = _dynamicMode;
    
    _dynamicMode = dynamicMode;
    
    if (oldMode != dynamicMode) {
        [self linkForDisplay];
    }
}

- (void)setBlurRatio:(CGFloat)blurRatio
{
    CGFloat oldRatio = self.blurRatio;
    
    _blurRatio = blurRatio;
    
    if (oldRatio != blurRatio) {
        if (self.staticImage) {
            [self updateCaptureImage:self.staticImage radius:self.blurRadius];
        }
    }
}

#pragma mark Override Methods

+ (Class)layerClass
{
    return [BlurLayer class];
}

- (void)didMoveToSuperview
{
    [super didMoveToSuperview];
    
    if (!self.superview) {
        if (self.displayLink) {
            [self.displayLink invalidate];
            self.displayLink = nil;
        }
        
    } else {
        [self linkForDisplay];
    }
}

// Borrowed form FXBlurView, slightly modified to directly animate blurRadius property
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event
{
    if ([event isEqualToString:@"blurRadius"]) {
        self.fromBlurRadius = nil;
        
        if (self.dynamicMode == DynamicModeNone) {
            self.staticImage = [self capturedImage];
            
        } else {
            if (self.staticImage) {
                self.staticImage = nil;
            }
        }
        
        CAAnimation *action = (CAAnimation *)[super actionForLayer:layer forKey:@"backgroundColor"];
        if ((NSNull *)action != [NSNull null]) {
            self.fromBlurRadius = @(self.blurPresentationLayer.blurRadius);
            
            CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:event];
            animation.fromValue = self.fromBlurRadius;
            animation.beginTime = action.beginTime;
            animation.duration = action.duration;
            animation.speed = action.speed;
            animation.timeOffset = action.timeOffset;
            animation.repeatCount = action.repeatCount;
            animation.repeatDuration = action.repeatDuration;
            animation.autoreverses = action.autoreverses;
            animation.fillMode = action.fillMode;
            animation.timingFunction = action.timingFunction;
            animation.delegate = action.delegate;
            
            return animation;
        }
    }
    
    return [super actionForLayer:layer forKey:event];
}

- (void)displayLayer:(CALayer *)layer
{
    CGFloat radius = 0;
    
    if (self.fromBlurRadius) {
        if (![self.layer presentationLayer]) {
            radius = [self.fromBlurRadius floatValue];
        
        } else {
            radius = self.blurPresentationLayer.blurRadius;
        }
    
    } else {
        radius = self.blurLayer.blurRadius;
    }
    
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        UIImage *capture = weakSelf.staticImage ?: [weakSelf capturedImage];
        [weakSelf updateCaptureImage:capture radius:self.blurRadius];
    });
}

#pragma mark Public Methods

- (void)refresh
{
    self.staticImage = nil;
    self.fromBlurRadius = nil;
    self.blurRatio = 1;
    
    [self displayLayer:self.blurLayer];
}

- (void)remove
{
    self.staticImage = nil;
    self.fromBlurRadius = nil;
    self.blurRatio = 1;
    
    self.layer.contents = nil;
}

#pragma mark Private Methods

- (void)linkForDisplay
{
    if (self.displayLink) {
        [self.displayLink invalidate];
    }

    self.displayLink = [[UIScreen mainScreen] displayLinkWithTarget:self selector:self.displayLinkSelector];
    
    if (self.displayLink) {
        
        NSString *loopMode;
        
        switch (self.dynamicMode) {
            case DynamicModeTracking:
            default:
                loopMode = UITrackingRunLoopMode;
                break;
                
            case DynamicModeCommon:
                loopMode = NSRunLoopCommonModes;
                break;
            
            case DynamicModeNone:
                loopMode = @"";
                break;
        }
        
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:loopMode];
    }
    
}

- (void)updateCaptureImage:(UIImage *)image radius:(CGFloat)radius
{
    __weak typeof(self) weakSelf = self;
    
    void (^updateImage)(void) = ^{
        UIImage *blurredImage = [image blurredImageWithRadius:weakSelf.blurRadius ratio:weakSelf.blurRatio iterations:weakSelf.iterations tintColor:weakSelf.tintColor];
        
        if (blurredImage) {
            dispatch_sync(dispatch_get_main_queue(), ^{
                [weakSelf updateContentImage:blurredImage];
            });
        }
    };
    
    if ([NSThread currentThread].isMainThread) {
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), updateImage);
        
    } else {
        updateImage();
    }
}

- (void)updateContentImage:(UIImage *)image
{
    self.layer.contents = (__bridge id)([image CGImage]);
    self.layer.contentsScale = image.scale;
}

// Borrowed from FXBlurView, straight up
- (NSArray *)prepareLayer
{
    __strong CALayer *blurlayer = self.blurLayer;
    __strong CALayer *underlyingLayer = self.superview.layer;
    while (blurlayer.superlayer && blurlayer.superlayer != underlyingLayer)
    {
        blurlayer = blurlayer.superlayer;
    }
    NSMutableArray *layers = [NSMutableArray array];
    NSUInteger index = [underlyingLayer.sublayers indexOfObject:blurlayer];
    if (index != NSNotFound)
    {
        for (NSUInteger i = index; i < [underlyingLayer.sublayers count]; i++)
        {
            CALayer *layer = underlyingLayer.sublayers[i];
            if (!layer.hidden)
            {
                layer.hidden = YES;
                [layers addObject:layer];
            }
        }
    }
    return layers;
}

- (void)restoreLayer:(NSArray *)layers
{
    for (CALayer *layer in layers) {
        layer.hidden = NO;
    }
}

- (UIImage *)capturedImage
{
    if (self.superview) {
        CGRect bounds = [self.blurLayer convertRect:self.blurLayer.bounds toLayer:self.superview.layer];
        
        UIGraphicsBeginImageContextWithOptions(bounds.size, YES, 1);
        CGContextRef context = UIGraphicsGetCurrentContext();
        CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
        
        if ([NSThread currentThread].isMainThread) {
            [self renderInContext:context];
        
        } else {
            
            __weak typeof(self) weakSelf = self;
            dispatch_sync(dispatch_get_main_queue(), ^{
                [weakSelf renderInContext:context];
            });
        }
        
        UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
        
        return image;
    }
    
    return nil;
}

- (void)renderInContext:(CGContextRef)context
{
    NSArray *layers = [self prepareLayer];
    
    if (self.fullScreenCapture && self.dynamicMode == DynamicModeNone) {
        if (self.superview) {
            [UIView setAnimationsEnabled:NO];
            [self.superview snapshotViewAfterScreenUpdates:YES];
            [UIView setAnimationsEnabled:YES];
        }
        
    } else {
        if (self.superview) {
            [self.superview.layer renderInContext:context];
        }
    }
    
    if (layers) {
        [self restoreLayer:layers];
    }
}

- (void)displayDidRefresh:(CADisplayLink *)displayLink
{
    [self displayLayer:self.blurLayer];
}

@end
