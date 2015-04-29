//
//  CyBlurView.h
//  CyBlurView
//
//  Created by Skyler Whittlesey on 4/29/15.
//  Copyright (c) 2015 Skyler Whittlesey. All rights reserved.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, DynamicMode) {
    DynamicModeTracking,
    DynamicModeCommon,
    DynamicModeNone
};

@interface CyBlurView : UIView

@property (nonatomic, assign) CGFloat blurRadius;
@property (nonatomic, assign) DynamicMode dynamicMode;
@property (nonatomic, assign) NSUInteger iterations;
@property (nonatomic, assign) BOOL fullScreenCapture;
@property (nonatomic, assign) CGFloat blurRatio;

@property (nonatomic, strong) UIColor *tintColor;

- (void)refresh;
- (void)remove;

@end
