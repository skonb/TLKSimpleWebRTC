# TLKSimpleWebRTC for the current Signalmaster

A version of [TLKSimpleWebRTC](https://github.com/otalk/TLKSimpleWebRTC) which uses the official [Socket.IO client](https://github.com/socketio/socket.io-client-swift) for communicating with [Signalmaster](https://github.com/andyet/signalmaster). 

## What is this all about? 
At the time this document written, **Signalmaster** uses **Socket.IO** 1.3.7, while [AZSocketIO](https://github.com/lukabernardi/AZSocketIO), which is basis of socket communication in **TLKSimpleWebRTC**, uses 0.9. Since handshaking protocol between **Socket.IO** 0.9 and 1.0+ is different, **TLKSimpleWebRTC** is not working with the current **Signalmaster** anymore. Meanwhile, **Socket.IO** released their own iOS/OSX version, so this fork aims to use this implementation and create a compatible version with the latest **Signalmaster**.

# Usage 

Usage is mostly the same with the original version, you can check [original project](https://github.com/otalk/TLKSimpleWebRTC) for further instructions. Differences are mentioned in the related section. 

## Build Environment

Creating the build environment is a bit different than the original version. 

First download / clone and add files under the `Classes` folder to your project. Repeat this for the [TLKWebRTC](https://github.com/otalk/TLKWebRTC.git) project. 

Afterwards add following lines to your Podfile;

    use_frameworks!

    pod 'libjingle_peerconnection'
    pod 'Socket.IO-Client-Swift'

## Differences from the TLKSimpleWebRTC

* There is a new initializer for managing connection configuration. It can be used like this;

    NSDictionary * config = @{@"selfSigned": @YES, @"sessionDelegate" : self};
    [self.signaling connectToServer:@"https://192.168.0.102" port: 3000 config: config success:^{
    } failure:^(NSString* error) {
        NSLog(@"connect failure");
    }];

For the full list of possible options please refer to [Socket.IO client documentation](https://github.com/socketio/socket.io-client-swift#options).

* Failures are reported with `NSString` instead of `NSError`. 

