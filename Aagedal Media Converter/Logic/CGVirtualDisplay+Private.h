// Aagedal Media Converter
// Copyright © 2025 Truls Aagedal
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Hand-authored declarations for Apple's private CoreGraphics virtual-display
// classes (CGVirtualDisplay & friends). These are interface *facts* about a
// system API — method signatures and property names needed to message classes
// that already live inside CoreGraphics at runtime. No third-party source is
// copied here; the file is original to this project and GPL-3.0-or-later like
// the rest of it.
//
// The classes are resolved from CoreGraphics (which the app already links), so
// no extra library or symbol is introduced. VirtualDisplayManager guards every
// use behind a runtime availability check (NSClassFromString) so the app keeps
// working if Apple ever changes or removes these private classes.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic) uint32_t vendorID;   // must be non-zero or display creation fails
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNum;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGPoint redPrimary;
@property (nonatomic) CGPoint greenPrimary;
@property (nonatomic) CGPoint bluePrimary;
@property (nonatomic) CGPoint whitePoint;
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@end

@interface CGVirtualDisplayMode : NSObject
- (nullable instancetype)initWithWidth:(NSUInteger)width
                                height:(NSUInteger)height
                           refreshRate:(double)refreshRate;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic) BOOL hiDPI;
@property (nonatomic, copy) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplay : NSObject
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) CGDirectDisplayID displayID;
@end

NS_ASSUME_NONNULL_END
