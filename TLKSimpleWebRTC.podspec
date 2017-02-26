Pod::Spec.new do |s|
  s.name         = "TLKSimpleWebRTC"
  s.version      = "1.1.0"
  s.summary      = "A iOS interface to a SimpleWebRTC based signalling server using Socket.io"
  s.homepage     = "https://github.com/skonb/TLKSimpleWebRTC"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "Jon Hjelle" => "hjon@andyet.com",
                     "&yet" => "contact@andyet.com" }
  s.platform     = :ios, '7.0'
  s.source       = { :git => "https://github.com/skonbTLKSimpleWebRTC.git", :tag => s.version.to_s }
  s.source_files = "Classes/*.{h,m}"
  s.requires_arc = true
  s.dependency 'Socket.IO-Client-Swift', '~> 8.2.0'
end
