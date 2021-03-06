/*
 * LoggerConnection.m
 *
 * BSD license follows (http://www.opensource.org/licenses/bsd-license.php)
 * 
 * Copyright (c) 2010 Florent Pillet <fpillet@gmail.com> All Rights Reserved.
 *
 * Redistribution and use in source and binary forms, with or without modification,
 * are permitted provided that the following conditions are met:
 *
 * Redistributions of  source code  must retain  the above  copyright notice,
 * this list of  conditions and the following  disclaimer. Redistributions in
 * binary  form must  reproduce  the  above copyright  notice,  this list  of
 * conditions and the following disclaimer  in the documentation and/or other
 * materials  provided with  the distribution.  Neither the  name of  Florent
 * Pillet nor the names of its contributors may be used to endorse or promote
 * products  derived  from  this  software  without  specific  prior  written
 * permission.  THIS  SOFTWARE  IS  PROVIDED BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT
 * NOT LIMITED TO, THE IMPLIED  WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
 * A  PARTICULAR PURPOSE  ARE DISCLAIMED.  IN  NO EVENT  SHALL THE  COPYRIGHT
 * HOLDER OR  CONTRIBUTORS BE  LIABLE FOR  ANY DIRECT,  INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY,  OR CONSEQUENTIAL DAMAGES (INCLUDING,  BUT NOT LIMITED
 * TO, PROCUREMENT  OF SUBSTITUTE GOODS  OR SERVICES;  LOSS OF USE,  DATA, OR
 * PROFITS; OR  BUSINESS INTERRUPTION)  HOWEVER CAUSED AND  ON ANY  THEORY OF
 * LIABILITY,  WHETHER  IN CONTRACT,  STRICT  LIABILITY,  OR TORT  (INCLUDING
 * NEGLIGENCE  OR OTHERWISE)  ARISING  IN ANY  WAY  OUT OF  THE  USE OF  THIS
 * SOFTWARE,   EVEN  IF   ADVISED  OF   THE  POSSIBILITY   OF  SUCH   DAMAGE.
 * 
 */
#import <objc/runtime.h>
#import "LoggerConnection.h"
#import "LoggerMessage.h"
#import "LoggerCommon.h"
#import "LoggerAppDelegate.h"
#import "LoggerStatusWindowController.h"

char sConnectionAssociatedObjectKey = 1;

@implementation LoggerConnection

@synthesize delegate;
@synthesize messages;
@synthesize connected, restoredFromSave, attachedToWindow;
@synthesize clientName, clientVersion, clientOSName, clientOSVersion, clientDevice;
@synthesize messageProcessingQueue;
@synthesize filenames, functionNames;

- (id)init
{
	if (self = [super init])
	{
		messageProcessingQueue = dispatch_queue_create("com.florentpillet.nslogger.messageProcessingQueue", NULL);
		messages = [[NSMutableArray alloc] initWithCapacity:1024];
		parentIndexesStack = [[NSMutableArray alloc] init];
		filenames = [[NSMutableSet alloc] init];
		functionNames = [[NSMutableSet alloc] init];
	}
	return self;
}

- (id)initWithAddress:(NSData *)anAddress
{
	if ((self = [super init]) != nil)
	{
		messageProcessingQueue = dispatch_queue_create("com.florentpillet.nslogger.messageProcessingQueue", NULL);
		messages = [[NSMutableArray alloc] initWithCapacity:1024];
		parentIndexesStack = [[NSMutableArray alloc] init];
		clientAddress = [anAddress copy];
		filenames = [[NSMutableSet alloc] init];
		functionNames = [[NSMutableSet alloc] init];
	}
	return self;
}

- (void)dealloc
{
	dispatch_release(messageProcessingQueue);
	[messages release];
	[parentIndexesStack release];
	[clientName release];
	[clientVersion release];
	[clientOSName release];
	[clientOSVersion release];
	[clientDevice release];
	[clientAddress release];
	[filenames release];
	[functionNames release];
	[super dealloc];
}

- (void)messagesReceived:(NSArray *)msgs
{
	dispatch_async(messageProcessingQueue, ^{
		/* Code not functional yet
		 *
		NSRange range = NSMakeRange([messages count], [msgs count]);
		NSUInteger lastParent = NSNotFound;
		if ([parentIndexesStack count])
			lastParent = [[parentIndexesStack lastObject] intValue];
		
		for (NSUInteger i = 0, count = [msgs count]; i < count; i++)
		{
			// update cache for indentation
			LoggerMessage *message = [msgs objectAtIndex:i];
			switch (message.type)
			{
				case LOGMSG_TYPE_BLOCKSTART:
					[parentIndexesStack addObject:[NSNumber numberWithInt:range.location+i]];
					lastParent = range.location + i;
					break;
					
				case LOGMSG_TYPE_BLOCKEND:
					if ([parentIndexesStack count])
					{
						[parentIndexesStack removeLastObject];
						if ([parentIndexesStack count])
							lastParent = [[parentIndexesStack lastObject] intValue];
						else
							lastParent = NSNotFound;
					}
					break;
					
				default:
					if (lastParent != NSNotFound)
					{
						message.distanceFromParent = range.location + i - lastParent;
						message.indent = [parentIndexesStack count];
					}
					break;
			}
		}
		 *
		 */
		NSRange range;
		@synchronized (messages)
		{
			range = NSMakeRange([messages count], [msgs count]);
			[messages addObjectsFromArray:msgs];
		}
		
		if (attachedToWindow)
			[self.delegate connection:self didReceiveMessages:msgs range:range];
	});
}

- (void)clientInfoReceived:(LoggerMessage *)message
{
	// Insert message at first position in the message list. In the unlikely event there is
	// an existing ClientInfo message at this position, just replace it. Also, don't fire
	// a "didReceiveMessages". The rationale behind this is that if the connection just came in,
	// we are not yet attached to a window and when attaching, the window will refresh all messages.
	dispatch_async(messageProcessingQueue, ^{
		@synchronized (messages)
		{
			if ([messages count] == 0 || ((LoggerMessage *)[messages objectAtIndex:0]).type != LOGMSG_TYPE_CLIENTINFO)
				[messages insertObject:message atIndex:0];
		}
	});

	// all this stuff occurs on the main thread to avoid touching values
	// while the UI reads them
	dispatch_async(dispatch_get_main_queue(), ^{
		NSDictionary *parts = message.parts;
		id value = [parts objectForKey:[NSNumber numberWithInteger:PART_KEY_CLIENT_NAME]];
		if (value != nil)
			self.clientName = value;
		value = [parts objectForKey:[NSNumber numberWithInteger:PART_KEY_CLIENT_VERSION]];
		if (value != nil)
			self.clientVersion = value;
		value = [parts objectForKey:[NSNumber numberWithInteger:PART_KEY_OS_NAME]];
		if (value != nil)
			self.clientOSName = value;
		value = [parts objectForKey:[NSNumber numberWithInteger:PART_KEY_OS_VERSION]];
		if (value != nil)
			self.clientOSVersion = value;
		value = [parts objectForKey:[NSNumber numberWithInteger:PART_KEY_CLIENT_MODEL]];
		if (value != nil)
			self.clientDevice = value;
	});
}

- (NSString *)clientAppDescription
{
	// enforce thread safety (only on main thread)
	assert([NSThread isMainThread]);
	NSMutableString *s = [[[NSMutableString alloc] init] autorelease];
	if (clientName != nil)
		[s appendString:clientName];
	if (clientVersion != nil)
		[s appendFormat:@" %@", clientVersion];
	if (clientName == nil && clientVersion == nil)
		[s appendString:NSLocalizedString(@"<unknown>", @"")];
	if (clientOSName != nil && clientOSVersion != nil)
		[s appendFormat:@"%@(%@ %@)", [s length] ? @" " : @"", clientOSName, clientOSVersion];
	else if (clientOSName != nil)
		[s appendFormat:@"%@(%@)", [s length] ? @" " : @"", clientOSName];

	return s;
}

- (NSString *)clientAddressDescription
{
	// subclasses should implement this
	return @"";
}

- (NSString *)clientDescription
{
	// enforce thread safety (only on main thread)
	assert([NSThread isMainThread]);
	return [NSString stringWithFormat:@"%@ @ %@", [self clientAppDescription], [self clientAddressDescription]];
}

- (NSString *)status
{
	// status is being observed by LoggerStatusWindowController and changes once
	// when the connection gets disconnected
	NSString *format;
	if (connected)
		format = NSLocalizedString(@"%@ connected", @"");
	else
		format = NSLocalizedString(@"%@ disconnected", @"");
	if ([NSThread isMainThread])
		return [NSString stringWithFormat:format, [self clientDescription]];
	__block NSString *status;
	dispatch_sync(dispatch_get_main_queue(), ^{
		status = [[NSString stringWithFormat:format, [self clientDescription]] retain];
	});
	return [status autorelease];
}

- (void)setConnected:(BOOL)newConnected
{
	if (connected != newConnected)
	{
		connected = newConnected;
		
		if (!connected && [(id)delegate respondsToSelector:@selector(remoteDisconnected:)])
			[(id)delegate performSelectorOnMainThread:@selector(remoteDisconnected:) withObject:self waitUntilDone:NO];

		[[NSNotificationCenter defaultCenter] postNotificationName:kShowStatusInStatusWindowNotification
															object:self];
	}
}

- (void)shutdown
{
	self.connected = NO;
}

// -----------------------------------------------------------------------------
#pragma mark -
#pragma mark NSCoding
// -----------------------------------------------------------------------------
- (id)initWithCoder:(NSCoder *)aDecoder
{
	if (self = [super init])
	{
		clientName = [[aDecoder decodeObjectForKey:@"clientName"] retain];
		clientVersion = [[aDecoder decodeObjectForKey:@"clientVersion"] retain];
		clientOSName = [[aDecoder decodeObjectForKey:@"clientOSName"] retain];
		clientOSVersion = [[aDecoder decodeObjectForKey:@"clientOSVersion"] retain];
		clientDevice = [[aDecoder decodeObjectForKey:@"clientDevice"] retain];
		parentIndexesStack = [[aDecoder decodeObjectForKey:@"parentIndexes"] retain];
		filenames = [[aDecoder decodeObjectForKey:@"filenames"] retain];
		if (filenames == nil)
			filenames = [[NSMutableSet alloc] init];
		functionNames = [[aDecoder decodeObjectForKey:@"functionNames"] retain];
		if (functionNames == nil)
			functionNames = [[NSMutableSet alloc] init];
		objc_setAssociatedObject(aDecoder, &sConnectionAssociatedObjectKey, self, OBJC_ASSOCIATION_ASSIGN);
		messages = [[aDecoder decodeObjectForKey:@"messages"] retain];
		restoredFromSave = YES;
		
		// we need a messageProcessingQueue just for the ability to add/insert marks
		// when user does post-mortem investigation
		messageProcessingQueue = dispatch_queue_create("com.florentpillet.nslogger.messageProcessingQueue", NULL);
	}
	return self;
}

- (void)encodeWithCoder:(NSCoder *)aCoder
{
	if (clientName != nil)
		[aCoder encodeObject:clientName forKey:@"clientName"];
	if (clientVersion != nil)
		[aCoder encodeObject:clientVersion forKey:@"clientVersion"];
	if (clientOSName != nil)
		[aCoder encodeObject:clientOSName forKey:@"clientOSName"];
	if (clientOSVersion != nil)
		[aCoder encodeObject:clientOSVersion forKey:@"clientOSVersion"];
	if (clientDevice != nil)
		[aCoder encodeObject:clientDevice forKey:@"clientDevice"];
	[aCoder encodeObject:filenames forKey:@"filenames"];
	[aCoder encodeObject:functionNames forKey:@"functionNames"];
	@synchronized (messages)
	{
		[aCoder encodeObject:messages forKey:@"messages"];
		[aCoder encodeObject:parentIndexesStack forKey:@"parentIndexes"];
	}
}

@end
