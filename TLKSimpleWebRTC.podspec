Pod::Spec.new do |s|
  s.name         = "TLKSimpleWebRTC"
  s.version      = "1.0.2"
  s.summary      = "TLKSimpleWebRTC implementation with official Socket.IO client"
  s.homepage     = "https://github.com/ujell/TLKSimpleWebRTC.git"
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author       = { "Jon Hjelle" => "hjon@andyet.com",
                     "&yet" => "contact@andyet.com",
                     "ujell" => "yuceluzun@windowslive.com" }
  s.platform     = :ios, '7.0'
  s.source       = { :git => "https://github.com/ujell/TLKSimpleWebRTC.git", :tag => s.version.to_s}
  s.source_files = "Classes/*.{h,m}"
  s.requires_arc = true
  s.dependency 'Socket.IO-Client-Swift', '~> 8.0.2'
end
