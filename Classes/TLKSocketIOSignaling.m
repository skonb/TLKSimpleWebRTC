//
//  TLKSocketIOSignaling.m
//  Copyright (c) 2014 &yet, LLC and TLKWebRTC contributors
//


#import "TLKSocketIOSignaling.h"
#import "TLKMediaStream.h"

#import "TLKWebRTC.h"
#import "RTCMediaStream.h"
#import "RTCICEServer.h"
#import "RTCVideoTrack.h"
#import "RTCAudioTrack.h"
@import SocketIO;

#define LOG_SIGNALING 1
#ifndef DLog
#if !defined(NDEBUG) && LOG_SIGNALING
#   define DLog(fmt, ...) NSLog((@"signaling: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif
#endif

#pragma mark - TLKMediaStream

@interface TLKMediaStream (Secrets)
{
}

@property (nonatomic, readwrite) RTCMediaStream *stream;
@property (nonatomic, readwrite) NSString *peerID;
@property (nonatomic, readwrite) BOOL videoMuted;
@property (nonatomic, readwrite) BOOL audioMuted;

@end

#pragma mark - TLKSocketIOSignaling

@interface TLKSocketIOSignaling () <
    TLKWebRTCDelegate>
{
    BOOL _localAudioMuted;
    BOOL _localVideoMuted;
}

@property (nonatomic, strong) SocketIOClient *socket;
@property (nonatomic, strong) TLKWebRTC *webRTC;

@property (nonatomic, readwrite) NSString *roomName;
@property (nonatomic, readwrite) NSString *roomKey;

@property (strong, readwrite, nonatomic) RTCMediaStream *localMediaStream;
@property (strong, readwrite, nonatomic) NSArray *remoteMediaStreamWrappers;

@property (strong, nonatomic) NSMutableSet *currentClients;

@end

@implementation TLKSocketIOSignaling

#pragma mark - getters/setters

- (BOOL)localAudioMuted {
    if (self.localMediaStream.audioTracks.count) {
        RTCAudioTrack *audioTrack = self.localMediaStream.audioTracks[0];
        return !audioTrack.isEnabled;
    }
    return YES;
}

- (void)setLocalAudioMuted:(BOOL)localAudioMuted {
    if(self.localMediaStream.audioTracks.count) {
        RTCAudioTrack *audioTrack = self.localMediaStream.audioTracks[0];
        [audioTrack setEnabled:!localAudioMuted];
        [self _sendMuteMessagesForTrack:@"audio" mute:localAudioMuted];
    }
}

- (BOOL)localVideoMuted {
    if (self.localMediaStream.videoTracks.count) {
        RTCVideoTrack* videoTrack = self.localMediaStream.videoTracks[0];
        return !videoTrack.isEnabled;
    }
    return YES;
}

- (void)setLocalVideoMuted:(BOOL)localVideoMuted {
    if (self.localMediaStream.videoTracks.count) {
        RTCVideoTrack* videoTrack = self.localMediaStream.videoTracks[0];
        [videoTrack setEnabled:!localVideoMuted];
        [self _sendMuteMessagesForTrack:@"video" mute:localVideoMuted];
    }
}

- (BOOL)isRoomLocked {
    return [self.roomKey length] > 0;
}

+ (NSSet *)keyPathsForValuesAffectingRoomLocked {
    return [NSSet setWithObject:@"roomKey"];
}

#pragma mark - object lifecycle

- (instancetype)initWithVideoDevice:(AVCaptureDevice *)device {
	self = [super init];
    if (self) {
    	if (device) {
			_allowVideo = YES;
			_videoDevice = device;
        }
        self.currentClients = [[NSMutableSet alloc] init];
    }
    return self;
}

- (instancetype)initWithVideo:(BOOL)allowVideo {
	// Set front camera as the default device
	AVCaptureDevice* frontCamera;
	if (allowVideo) {
		frontCamera = [[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] lastObject];
	}
	return [self initWithVideoDevice:frontCamera];
}

- (instancetype)init {
	// Use default device
	return [self initWithVideo:YES];
}

#pragma mark - peer/room utilities

- (void)_disconnectSocket {
    [self.socket disconnect];
    self.socket = nil;
}

- (TLKMediaStream *)_streamForPeerIdentifier:(NSString *)peerIdentifier {
    __block TLKMediaStream *found = nil;
    
    [self.remoteMediaStreamWrappers enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([((TLKMediaStream *)obj).peerID isEqualToString:peerIdentifier]) {
            found = obj;
            *stop = YES;
        }
    }];
    
    return found;
}

- (void)_peerDisconnectedForIdentifier:(NSString *)peerIdentifier {
    NSMutableArray* mutable = [self.remoteMediaStreamWrappers mutableCopy];
    NSMutableIndexSet* toRemove = [NSMutableIndexSet new];
    
    [mutable enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if ([((TLKMediaStream *)obj).peerID isEqualToString:peerIdentifier]) {
            [toRemove addIndex:idx];
        }
    }];
    
    NSArray* objects = [self.remoteMediaStreamWrappers objectsAtIndexes:toRemove];
    
    [mutable removeObjectsAtIndexes:toRemove];
    
    self.remoteMediaStreamWrappers = mutable;
    
    if ([self.delegate respondsToSelector:@selector(socketIOSignaling:removedStream:)]) {
        for (TLKMediaStream *stream in objects) {
            [self.delegate socketIOSignaling:self removedStream:stream];
        }
    }
}

#pragma mark - connect

- (void)connectToServer:(NSString*)apiServer success:(void(^)(void))successCallback failure:(void(^)(NSString*))failureCallback {
    [self connectToServer:apiServer port: 8888 config:@{@"secure": @YES} success:successCallback failure:failureCallback];
}

- (void)connectToServer:(NSString*)apiServer port:(int)port secure:(BOOL)secure success:(void(^)(void))successCallback failure:(void(^)(NSString*))failureCallback {
    [self connectToServer:apiServer port:port config:@{@"secure": [NSNumber numberWithBool: secure]} success:successCallback failure:failureCallback];
}

- (void)connectToServer:(NSString*)apiServer port:(int)port config:( NSDictionary *) config success:(void(^)(void))successCallback failure:(void(^)(NSString*))failureCallback {
    if (self.socket) {
        [self _disconnectSocket];
    }
    
    __weak TLKSocketIOSignaling *weakSelf = self;

    NSURL* url = [[NSURL alloc] initWithString: [NSString stringWithFormat:@"%@://%@:%d", (config[@"secure"].boolValue ? @"https" : @"http"), apiServer, port]];
    self.socket = [[SocketIOClient alloc] initWithSocketURL:url config: config];

    if (!self.webRTC) {
        if (self.allowVideo && self.videoDevice) {
            self.webRTC = [[TLKWebRTC alloc] initWithVideoDevice:self.videoDevice];
        } else {
            self.webRTC = [[TLKWebRTC alloc] initWithVideo:NO];
        }
        self.webRTC.delegate = self;
    }
    
    [self.socket on:@"connect" callback:^(NSArray* data, SocketAckEmitter* ack) {
        dispatch_async(dispatch_get_main_queue(), ^{
            TLKSocketIOSignaling *strongSelf = weakSelf;
            strongSelf.localMediaStream = strongSelf.webRTC.localMediaStream;
            
            if (successCallback) {
                successCallback();
            }
        });
    }];
    
    [self.socket on:@"message" callback:^(NSArray* data, SocketAckEmitter* ack) {
        [weakSelf _socketMessageReceived:data];
    }];
    
    [self.socket on:@"error" callback:^(NSArray* data, SocketAckEmitter* ack) {
        DLog(@"Failed to connect socket.io: %@", data[0]);
        if (failureCallback) {
            failureCallback(data[0]);
        }
    }];
    
    [self.socket on:@"disconnect" callback:^(NSArray* data, SocketAckEmitter* ack) {
         [weakSelf _socketDisconnected];
    }];

    [self.socket onAny:^(SocketAnyEvent* e) {
        if (![e.event isEqualToString:@"connect"] &&
            ![e.event isEqualToString:@"disconnect"] &&
            ![e.event isEqualToString:@"error"])
        {
            [weakSelf _socketEventReceived: e.event withData: e.items];
        }
    }];
    
    [self.socket connect];
}

- (void)joinRoom:(NSString*)room withKey:(NSString*)key success:(void(^)(void))successCallback failure:(void(^)(void))failureCallback {
    NSMutableArray * args = [NSMutableArray new];
    [args addObject: room];
    if (key) {
        [args addObject: key];
    }
    
    
    [[self.socket emitWithAck: @"join" with:args] timingOutAfter:0 callback:^(NSArray* data) {
        if (data[0] == [NSNull null]) {
            NSDictionary* clients = data[1][@"clients"];
            
            [[clients allKeys] enumerateObjectsUsingBlock:^(id peerID, NSUInteger idx, BOOL *stop) {
                [self.webRTC addPeerConnectionForID:peerID];
                [self.webRTC createOfferForPeerWithID:peerID];
                
                [self.currentClients addObject:peerID];
            }];
            
            self.roomName = room;
            self.roomKey = key;
            
            if(successCallback) {
                successCallback();
            }
        } else {
            NSLog(@"Error: %@", data[0]);
            failureCallback();
        }
    }];
}

- (void)joinRoom:(NSString *)room success:(void(^)(void))successCallback failure:(void(^)(void))failureCallback {
    [self joinRoom:room withKey:nil success:successCallback failure:failureCallback];
}

- (void)leaveRoom {
    [[self.currentClients allObjects] enumerateObjectsUsingBlock:^(id peerID, NSUInteger idx, BOOL *stop) {
        [self.webRTC removePeerConnectionForID:peerID];
        [self _peerDisconnectedForIdentifier:peerID];
    }];
    
    self.currentClients = [[NSMutableSet alloc] init];
    
    [self _disconnectSocket];
}

- (void)lockRoomWithKey:(NSString *)key success:(void(^)(void))successCallback failure:(void(^)(void))failureCallback {
    [[self.socket emitWithAck: @"lockRoom" with:@[key]] timingOutAfter:0 callback:^(NSArray* data) {
        if (data[0] == [NSNull null]) {
            if(successCallback) {
                successCallback();
            }
        } else {
            NSLog(@"Error: %@", data[0]);
            if(failureCallback) {
                failureCallback();
            }
        }
    }];
}

- (void)unlockRoomWithSuccess:(void(^)(void))successCallback failure:(void(^)(void))failureCallback {
    [[self.socket emitWithAck: @"unlockRoom" with: @[]] timingOutAfter:0 callback:^(NSArray* data) {
        if (data[0] == [NSNull null]) {
            if(successCallback) {
                successCallback();
            }
        } else {
            NSLog(@"Error: %@", data[0]);
            if(failureCallback) {
                failureCallback();
            }
        }
    }];
}

#pragma mark - Mute/Unmute utilities

- (void)_sendMuteMessagesForTrack:(NSString *)trackString mute:(BOOL)mute {
    for (NSString* peerID in self.currentClients) {
        [self.socket emit:@"message" with:@[@{@"to":peerID, @"type" : mute ? @"mute" : @"unmute",  @"payload": @{@"name":trackString}}]];
    }
}

- (void)_broadcastMuteStates {
    [self _sendMuteMessagesForTrack:@"audio" mute:self.localAudioMuted];
    [self _sendMuteMessagesForTrack:@"video" mute:self.localVideoMuted];
}

#pragma mark - SocketIO methods

- (void)_socketMessageReceived:(id)data {
}

- (void)_socketEventReceived:(NSString*)eventName withData:(id)data {
    NSDictionary *dictionary = nil;

    if ([eventName isEqualToString:@"locked"]) {
        
        self.roomKey = (NSString*)[data objectAtIndex:0];
        if ([self.delegate respondsToSelector:@selector(socketIOSignaling:didChangeLock:)]) {
            [self.delegate socketIOSignaling:self didChangeLock:YES];
        }
        
    } else if ([eventName isEqualToString:@"unlocked"]) {
        
        self.roomKey = nil;
        if ([self.delegate respondsToSelector:@selector(socketIOSignaling:didChangeLock:)]) {
            [self.delegate socketIOSignaling:self didChangeLock:NO];
        }
        
    } else if ([eventName isEqualToString:@"passwordRequired"]) {
        
        if ([self.delegate respondsToSelector:@selector(socketIOSignalingRequiresServerPassword:)]) {
            [self.delegate socketIOSignalingRequiresServerPassword:self];
        }
        
    } else if ([eventName isEqualToString:@"stunservers"] || [eventName isEqualToString:@"turnservers"]) {
        
        NSArray *serverList = data[0];
        for (NSDictionary *info in serverList) {
            NSString *username = info[@"username"] ? info[@"username"] : @"";
            NSString *password = info[@"credential"] ? info[@"credential"] : @"";
            RTCICEServer *server = [[RTCICEServer alloc] initWithURI:[NSURL URLWithString:info[@"url"]] username:username password:password];
            if (server != nil)
                [self.webRTC addICEServer:server];
        }
    } else {
    
        dictionary = data[0];
        
        if (![dictionary isKindOfClass:[NSDictionary class]]) {
            dictionary = nil;
        }
    }

    NSLog(@"eventName = %@, type = %@, from = %@, to = %@",eventName, dictionary[@"type"], dictionary[@"from"], dictionary[@"to"]);
    
    NSDictionary * payload = dictionary[@"payload"];
    
    if ([dictionary[@"type"] isEqualToString:@"iceFailed"]) {
    
        [[[UIAlertView alloc] initWithTitle:@"Connection Failed" message:@"Talky could not establish a connection to a participant in this chat. Please try again later." delegate:nil cancelButtonTitle:@"Continue" otherButtonTitles:nil] show];
    
    } else if ([dictionary[@"type"] isEqualToString:@"candidate"]) {
        
        RTCICECandidate* candidate = [[RTCICECandidate alloc] initWithMid:payload[@"candidate"][@"sdpMid"]
                                                                    index:[payload[@"candidate"][@"sdpMLineIndex"] integerValue]
                                                                      sdp:payload[@"candidate"][@"candidate"]];
        
        [self.webRTC addICECandidate:candidate forPeerWithID:dictionary[@"from"]];
        
    } else if ([dictionary[@"type"] isEqualToString:@"answer"]) {
        
        RTCSessionDescription* remoteSDP = [[RTCSessionDescription alloc] initWithType:payload[@"type"]
                                                                                   sdp:payload[@"sdp"]];
        
        [self.webRTC setRemoteDescription:remoteSDP forPeerWithID:dictionary[@"from"] receiver:NO];
        
    } else if ([dictionary[@"type"] isEqualToString:@"offer"]) {
        
        [self.webRTC addPeerConnectionForID:dictionary[@"from"]];
        [self.currentClients addObject:dictionary[@"from"]];
        
        // Fix for browser-to-app connection crash using beta API.
        NSString* origSDP = payload[@"sdp"];
        NSError* error;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"m=application \\d+ DTLS/SCTP 5000 *"
                                                                               options:0
                                                                                 error:&error];
        
        NSString* sdp = [regex stringByReplacingMatchesInString:origSDP options:0 range:NSMakeRange(0, [origSDP length]) withTemplate:@"m=application 0 DTLS/SCTP 5000"];
        
        RTCSessionDescription* remoteSDP = [[RTCSessionDescription alloc] initWithType:payload[@"type"]
                                                                                   sdp:sdp];
        
        [self.webRTC setRemoteDescription:remoteSDP forPeerWithID:dictionary[@"from"] receiver:YES];
        
    } else if ([eventName isEqualToString:@"remove"]) {
        
        [self.webRTC removePeerConnectionForID:dictionary[@"id"]];
        [self _peerDisconnectedForIdentifier:dictionary[@"id"]];
        
        [self.currentClients removeObject:dictionary[@"id"]];
        
    }  else if ([dictionary[@"type"] isEqualToString:@"mute"] || [dictionary[@"type"] isEqualToString:@"unmute"]) {
        if ([payload[@"name"] isEqualToString:@"audio"]) {
            TLKMediaStream *stream = [self _streamForPeerIdentifier:dictionary[@"from"]];
            stream.audioMuted = [dictionary[@"type"] isEqualToString:@"mute"];
            if([self.delegate respondsToSelector:@selector(socketIOSignaling:peer:toggledAudioMute:)]) {
                [self.delegate socketIOSignaling:self peer:dictionary[@"from"] toggledAudioMute:stream.audioMuted];
            }
        } else if ([payload[@"name"] isEqualToString:@"video"]) {
            TLKMediaStream *stream = [self _streamForPeerIdentifier:dictionary[@"from"]];
            stream.videoMuted = [dictionary[@"type"] isEqualToString:@"mute"];
            if([self.delegate respondsToSelector:@selector(socketIOSignaling:peer:toggledVideoMute:)]) {
                [self.delegate socketIOSignaling:self peer:dictionary[@"from"] toggledVideoMute:stream.videoMuted];
            }
        }
    }
    else if ([eventName isEqualToString:@"message"]) {
        [_delegate socketIOSignaling: self recievedMessage: dictionary andData: data];
    }
}

- (void)_socketDisconnected {
}

- (void)_socketReceivedError:(NSError *)error {
    DLog(@"socket received error occured %@", error);
}

#pragma mark - TLKWebRTCDelegate

- (void)webRTC:(TLKWebRTC *)webRTC didSendSDPOffer:(RTCSessionDescription *)offer forPeerWithID:(NSString *)peerID {
    NSDictionary *args = @{@"to": peerID,
                           @"roomType": @"video",
                           @"type": offer.type,
                           @"payload": @{@"type": offer.type, @"sdp": offer.description}};
    [self.socket emit:@"message" with:@[args]];
}

- (void)webRTC:(TLKWebRTC *)webRTC didSendSDPAnswer:(RTCSessionDescription *)answer forPeerWithID:(NSString* )peerID {
    NSDictionary *args = @{@"to": peerID,
                           @"roomType": @"video",
                           @"type": answer.type,
                           @"payload": @{@"type": answer.type, @"sdp": answer.description}};
    [self.socket emit:@"message" with:@[args]];
}

- (void)webRTC:(TLKWebRTC *)webRTC didSendICECandidate:(RTCICECandidate *)candidate forPeerWithID:(NSString *)peerID {
    NSDictionary *args = @{@"to": peerID,
                           @"roomType": @"video",
                           @"type": @"candidate",
                           @"payload": @{ @"candidate" : @{@"sdpMid": candidate.sdpMid,
                                                           @"sdpMLineIndex": [NSString stringWithFormat:@"%ld", (long)candidate.sdpMLineIndex],
                                                           @"candidate": candidate.sdp}}};
    [self.socket emit:@"message" with:@[args]];
}

- (void)webRTC:(TLKWebRTC *)webRTC didObserveICEConnectionStateChange:(RTCICEConnectionState)state forPeerWithID:(NSString *)peerID {
    if ((state == RTCICEConnectionConnected) || (state == RTCICEConnectionClosed)) {
        [self _broadcastMuteStates];
    }
    else if (state == RTCICEConnectionFailed) {
        NSDictionary *args = @{@"to": peerID,
                               @"type": @"iceFailed"};
        [self.socket emit:@"message" with:@[args]];
        [[[UIAlertView alloc] initWithTitle:@"Connection Failed" message:@"Talky could not establish a connection to a participant in this chat. Please try again later." delegate:nil cancelButtonTitle:@"Continue" otherButtonTitles:nil] show];
    }
}

- (void)webRTC:(TLKWebRTC *)webRTC addedStream:(RTCMediaStream *)stream forPeerWithID:(NSString *)peerID {
    TLKMediaStream *tlkStream = [TLKMediaStream new];
    tlkStream.stream = stream;
    tlkStream.peerID = peerID;
    
    if (!self.remoteMediaStreamWrappers) {
        self.remoteMediaStreamWrappers = @[tlkStream];
    }
    else {
        self.remoteMediaStreamWrappers = [self.remoteMediaStreamWrappers arrayByAddingObject:tlkStream];
    }
    
    if ([self.delegate respondsToSelector:@selector(socketIOSignaling:addedStream:)]) {
        [self.delegate socketIOSignaling:self addedStream:tlkStream];
    }
}

- (void)webRTC:(TLKWebRTC *)webRTC removedStream:(RTCMediaStream *)stream forPeerWithID:(NSString *)peerID {
    NSMutableArray *mutable = [self.remoteMediaStreamWrappers mutableCopy];
    NSMutableIndexSet *toRemove = [NSMutableIndexSet new];
    
    [mutable enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        if (((TLKMediaStream *)obj).stream == stream) {
            [toRemove addIndex:idx];
        }
    }];
    
    NSArray *objects = [self.remoteMediaStreamWrappers objectsAtIndexes:toRemove];
    
    [mutable removeObjectsAtIndexes:toRemove];
    
    self.remoteMediaStreamWrappers = mutable;
    
    if ([self.delegate respondsToSelector:@selector(socketIOSignaling:removedStream:)]) {
        for (TLKMediaStream *stream in objects) {
            [self.delegate socketIOSignaling:self removedStream:stream];
        }
    }
}

@end
