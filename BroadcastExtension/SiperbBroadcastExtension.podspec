require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

# The extension half of iOS screen capture, as a pod for the app's Broadcast Upload Extension
# TARGET — not for the app target, which gets the receiving half through siperb-rn-webrtc's own
# podspec. Separate on purpose: an extension has a ~50 MB budget, so this depends on nothing.
#
#   target 'SiperbBroadcastExtension' do
#     pod 'SiperbBroadcastExtension', :path => '../node_modules/siperb-rn-webrtc/BroadcastExtension'
#   end
#
# Kept OUT of ios/ because the main podspec globs ios/**/*.{h,m} into the app.
Pod::Spec.new do |s|
  s.name                = 'SiperbBroadcastExtension'
  s.version             = package['version']
  s.summary             = 'Broadcast Upload Extension sample handler for siperb-rn-webrtc screen capture'
  s.description         = 'RPBroadcastSampleHandler that streams ReplayKit frames to the siperb-rn-webrtc screen capturer in the host app over an App Group socket.'
  s.homepage            = 'https://github.com/Siperb/siperb-rn-webrtc'
  s.license             = package['license']
  s.author              = 'https://github.com/Siperb/siperb-rn-webrtc/graphs/contributors'
  s.source              = { :git => 'git@github.com:Siperb/siperb-rn-webrtc.git', :tag => "release #{s.version}" }
  s.requires_arc        = true

  s.platforms           = { :ios => '12.0' }

  s.source_files        = '*.{h,m}'
  s.public_header_files = 'SiperbBroadcastSampleHandler.h'
  s.frameworks          = 'CoreGraphics', 'CoreImage', 'CoreMedia', 'CoreVideo', 'Foundation', 'ImageIO', 'ReplayKit'

  # Extension-safe APIs only: the compiler then rejects anything that would be unavailable in
  # an app extension, instead of it crashing at launch.
  s.pod_target_xcconfig = { 'APPLICATION_EXTENSION_API_ONLY' => 'YES' }
end
