//
//  MMCloudKitManager.m
//  LooseLeaf
//
//  Created by Adam Wulf on 8/22/14.
//  Copyright (c) 2014 Milestone Made, LLC. All rights reserved.
//

#import "MMCloudKitManager.h"
#import <SimpleCloudKitManager/SPRSimpleCloudKitManager.h>
#import "NSThread+BlockAdditions.h"
#import "MMReachabilityManager.h"
#import "MMCloudKitDeclinedPermissionState.h"
#import "MMCloudKitAccountMissingState.h"
#import "MMCloudKitAskingForPermissionState.h"
#import "MMCloudKitOfflineState.h"
#import "MMCloudKitWaitingForLoginState.h"
#import "MMCloudKitLoggedInState.h"
#import "MMCloudKitFetchFriendsState.h"
#import "MMCloudKitFetchingAccountInfoState.h"
#import "NSFileManager+DirectoryOptimizations.h"
#import "NSArray+Extras.h"
#import <ZipArchive/ZipArchive.h>

#define kMessagesSinceLastFetchKey @"messagesSinceLastFetch"

@implementation MMCloudKitManager{
    MMCloudKitBaseState* currentState;
    NSString* cachePath;
    
    NSMutableDictionary* incomingMessageState;
}

@synthesize delegate;
@synthesize currentState;

static dispatch_queue_t messageQueue;

+(dispatch_queue_t) messageQueue{
    if(!messageQueue){
        messageQueue = dispatch_queue_create("com.milestonemade.looseleaf.messageQueue", DISPATCH_QUEUE_SERIAL);
    }
    return messageQueue;
}



- (id)init {
    self = [super init];
    if (self) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(cloudKitInfoDidChange) name:NSUbiquityIdentityDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reachabilityDidChange) name:kReachabilityChangedNotification object:nil];
        
        currentState = [[MMCloudKitBaseState alloc] init];
        
        dispatch_async([MMCloudKitManager messageQueue], ^{
            incomingMessageState = [NSMutableDictionary dictionaryWithContentsOfFile:[[self cachePath] stringByAppendingPathComponent:@"messages.plist"]];
            if(!incomingMessageState){
                incomingMessageState = [NSMutableDictionary dictionary];
                [incomingMessageState setObject:@[] forKey:kMessagesSinceLastFetchKey];
            }
        });
        
        // the UIApplicationDidBecomeActiveNotification will kickstart the process when the app launches
    }
    return self;
}

-(NSString*) cachePath{
    if(!cachePath){
        NSString* documentsPath = [NSFileManager documentsPath];
        cachePath = [documentsPath stringByAppendingPathComponent:@"CloudKit"];
        [NSFileManager ensureDirectoryExistsAtPath:cachePath];
    }
    return cachePath;
}

+ (MMCloudKitManager *) sharedManager {
    static dispatch_once_t onceToken;
    static MMCloudKitManager *manager;
    dispatch_once(&onceToken, ^{
        manager = [[MMCloudKitManager alloc] init];
    });
    return manager;
}

+(BOOL) isCloudKitAvailable{
    return [CKContainer class] != nil;
}

-(void) userRequestedToLogin{
    if([currentState isKindOfClass:[MMCloudKitWaitingForLoginState class]]){
        [(MMCloudKitWaitingForLoginState*)currentState didAskToLogin];
    }
}

-(void) changeToState:(MMCloudKitBaseState*)state{
    currentState = state;
    [currentState runState];
    [self.delegate cloudKitDidChangeState:currentState];
}

-(void) retryStateAfterDelay{
    [self performSelector:@selector(delayedRunStateFor:) withObject:currentState afterDelay:1];
}

-(void) delayedRunStateFor:(MMCloudKitBaseState*)aState{
    if(currentState == aState){
        [aState runState];
    }
}

-(BOOL) isLoggedInAndReadyForAnything{
    return [currentState isKindOfClass:[MMCloudKitLoggedInState class]];
}

-(void) fetchAllNewMessages{
    [[SPRSimpleCloudKitManager sharedManager] fetchNewMessagesWithCompletionHandler:^(NSArray *messages, NSError *error) {
        if(!error){
            for(SPRMessage* message in messages){
                [self processIncomingMessage:message];
            }
            [currentState cloudKitDidCheckForNotifications];
            
            // clear out any messages that we're tracking
            // since our last fetch-all-notifications
            dispatch_async([MMCloudKitManager messageQueue], ^{
                @synchronized(incomingMessageState){
                    [incomingMessageState setObject:[NSArray array] forKey:kMessagesSinceLastFetchKey];
                }
            });
        }
    }];
}

#pragma mark - Notifications

-(void) cloudKitInfoDidChange{
    // handle change in cloudkit
    [currentState cloudKitInfoDidChange];
}

-(void) applicationDidBecomeActive{
    [currentState applicationDidBecomeActive];
}

-(void) reachabilityDidChange{
    [currentState reachabilityDidChange];
}


-(void) processIncomingMessage:(SPRMessage*)unprocessedMessage{
    @synchronized(incomingMessageState){
        NSArray* messagesSinceLastFetch = [incomingMessageState objectForKey:kMessagesSinceLastFetchKey];
        if([messagesSinceLastFetch containsObject:unprocessedMessage]){
            return;
        }
    }
    
    dispatch_async([MMCloudKitManager messageQueue], ^{
        @synchronized(incomingMessageState){
            NSArray* messagesSinceLastFetch = [incomingMessageState objectForKey:kMessagesSinceLastFetchKey];
            if(![messagesSinceLastFetch containsObject:unprocessedMessage]){
                [incomingMessageState setObject:[messagesSinceLastFetch arrayByAddingObject:unprocessedMessage] forKey:kMessagesSinceLastFetchKey];
            }
        }
    });
    

    
    [self.delegate willFetchMessage:unprocessedMessage];
    // Do something with the message, like pushing it onto the stack
    [[SPRSimpleCloudKitManager sharedManager] fetchDetailsForMessage:unprocessedMessage withCompletionHandler:^(SPRMessage *message, NSError *error) {
        if(!error){
            ZipArchive* zip = [[ZipArchive alloc] init];
            if([zip validateZipFileAt:message.messageData.path]){
                [delegate didFetchMessage:message];
            }else{
                NSLog(@"invalid zip file");
                NSLog(@"zip at: %@", message.messageData.path);
                if(message.messageData.path){
                    NSString* savedPath = [[NSFileManager documentsPath] stringByAppendingPathComponent:[message.messageData.path lastPathComponent]];
                    [[NSFileManager defaultManager] moveItemAtPath:message.messageData.path toPath:savedPath error:nil];
                    NSLog(@"saved to: %@", savedPath);
                }
                [delegate didFailToFetchMessage:message];
            }
        }else{
            NSLog(@"invalid zip file");
            [delegate didFailToFetchMessage:message];
        }
        
        dispatch_async([MMCloudKitManager messageQueue], ^{
            // only remove completed messages
            @synchronized(incomingMessageState){
//                NSArray* messagesSinceLastFetch = [incomingMessageState objectForKey:kMessagesSinceLastFetchKey];
            }
        });
    }];
}

#pragma mark - Remote Notification

-(void) handleIncomingMessageNotification:(CKQueryNotification*)remoteNotification{
    [[SPRSimpleCloudKitManager sharedManager] messageForQueryNotification:remoteNotification withCompletionHandler:^(SPRMessage *message, NSError *error) {
        // notify that we're going to fetch message details
        [self processIncomingMessage:message];
    }];
    [self.currentState cloudKitDidRecievePush];
    [self fetchAllNewMessages];
}

#pragma mark - Description

-(NSString*) description{
    if([currentState isKindOfClass:[MMCloudKitFetchingAccountInfoState class]]){
        return @"loading account info";
    }else if([currentState isKindOfClass:[MMCloudKitFetchFriendsState class]]){
        return @"loading friends";
    }else if([currentState isKindOfClass:[MMCloudKitLoggedInState class]]){
        return @"logged in";
    }else if([currentState isKindOfClass:[MMCloudKitWaitingForLoginState class]]){
        return @"Needs User to Login";
    }else if([currentState isKindOfClass:[MMCloudKitAskingForPermissionState class]]){
        return @"Asking for permission";
    }else if([currentState isKindOfClass:[MMCloudKitOfflineState class]]){
        return @"Network Offline";
    }else if([currentState isKindOfClass:[MMCloudKitAccountMissingState class]]){
        return @"No Account";
    }else if([currentState isKindOfClass:[MMCloudKitDeclinedPermissionState class]]){
        return @"Permission Denied";
    }else{
        return @"initializing cloudkit";
    }
}
@end